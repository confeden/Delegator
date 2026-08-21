//! «Мышление» — a live vector map of what Delegator is doing right now.
//!
//! PROTOTYPE. It draws the PIPELINE, never the conversation: who asked, what the
//! router decided and why, which internal stage ran, through which channel, on
//! which model, and how it ended. That restriction is structural rather than a
//! promise — the record structs below have no field for `promptSummary` /
//! `outputPreview` / `errorPreview`, so the text of a task or an answer cannot
//! reach this module even by accident. Serde drops what it was never asked for.
//!
//! Three append-only sources, each contributing a different half of the picture:
//!   `router-decisions.jsonl` — client, tier, mode, the RULE that fired
//!   `usage.jsonl`            — the internal stages (triage, advisor, synthesis…)
//!   `runs.jsonl`             — attempts, failover and the error class
//!
//! Motion is deliberate and continuous: every known edge carries a slow ambient
//! particle so the map is never frozen, a freshly used edge burns bright, and an
//! edge seen for the FIRST time flashes in its own colour. A static picture
//! would be indistinguishable from a broken reader — which is exactly the bug
//! this file shipped with the first time.

use crate::config::runtime_home_dir;
use crate::theme::ThemeConfig;
use eframe::egui;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How often the logs are re-read. Only while the tab is on screen: a hidden
/// window gets no paint messages, so nothing polls from the tray.
const POLL_INTERVAL: Duration = Duration::from_millis(600);

/// Bytes of history read on the first poll to seed a populated map.
const SEED_BYTES: u64 = 128 * 1024;

/// Reserved strip under the map. Without it the hover line is pushed out of the
/// panel and clipped — the map happily takes every pixel it is offered.
const FOOTER_HEIGHT: f32 = 58.0;

/// Per column. Beyond this the quietest nodes are folded into a «+N ещё» marker
/// rather than squeezed into unreadable slivers.
const MAX_NODES_PER_STAGE: usize = 9;

/// Seconds an edge counts as "just used" / "brand new".
const EDGE_HOT_SECS: f64 = 3.0;
const EDGE_NEW_SECS: f64 = 6.0;

const GLOW_DECAY_PER_SEC: f32 = 0.5;
const PULSE_SPEED_PER_SEC: f32 = 0.9;
/// Delay between consecutive hops so one event visibly CASCADES down the
/// pipeline instead of lighting every column at once.
const HOP_DELAY_SECS: f32 = 0.16;

/// Router decision. `reason` is a fixed rule name (`code-task`, `keep-trivial`,
/// …) chosen from a closed set in router.py — never user text.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct RouterLine {
    mode: String,
    reason: String,
    tier: String,
    client: String,
    confidence: f32,
    #[serde(rename = "routeMs")]
    route_ms: u64,
}

/// One usage record. This is where the INTERNAL stages come from — triage,
/// advisor, synthesis, extract — the processes that were invisible before.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct UsageLine {
    client: String,
    stage: String,
    mode: String,
    provider: String,
    model: String,
    #[serde(rename = "totalTokens")]
    total_tokens: Option<u64>,
    #[serde(rename = "elapsedMs")]
    elapsed_ms: u64,
    ok: Option<bool>,
}

/// One runtime event: attempts and failover, which usage.jsonl cannot show.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct RunLine {
    event: String,
    status: String,
    domain: String,
    model: String,
    #[serde(rename = "executionPath")]
    execution_path: String,
    #[serde(rename = "errorClass")]
    error_class: String,
    #[serde(rename = "elapsedMs")]
    elapsed_ms: u64,
}

/// Columns, left to right. The columns ARE the pipeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Stage {
    Source = 0,
    Router = 1,
    Mode = 2,
    Process = 3,
    Channel = 4,
    Model = 5,
    Outcome = 6,
}

impl Stage {
    const ALL: [Stage; 7] = [
        Stage::Source,
        Stage::Router,
        Stage::Mode,
        Stage::Process,
        Stage::Channel,
        Stage::Model,
        Stage::Outcome,
    ];

    fn title(self) -> &'static str {
        match self {
            Stage::Source => "Источник",
            Stage::Router => "Роутер",
            Stage::Mode => "Режим",
            Stage::Process => "Процесс",
            Stage::Channel => "Канал",
            Stage::Model => "Модель",
            Stage::Outcome => "Итог",
        }
    }
}

/// Russian names for the internal stages, so the column reads as processes
/// rather than as log keys.
fn process_label(stage: &str) -> &str {
    match stage {
        "answer" => "ответ",
        "triage" => "триаж",
        "extract" => "выжимка контекста",
        "advisor" => "советник",
        "synthesis" => "синтез",
        "critic" => "критик",
        "verify" => "проверка",
        "improve" => "правка черновика",
        "micro" => "микро-задача",
        "plan" => "план",
        "parallel" => "параллельно",
        "route" => "выбор режима",
        other => other,
    }
}

#[derive(Debug, Clone)]
struct Node {
    stage: Stage,
    label: String,
    detail: String,
    hits: u64,
    glow: f32,
    pos: egui::Pos2,
    failed: bool,
    visible: bool,
}

#[derive(Debug, Clone, Copy, Default)]
struct Edge {
    hits: u64,
    last_used: f64,
    first_seen: f64,
}

#[derive(Debug, Clone)]
struct Pulse {
    from: usize,
    to: usize,
    /// Seconds still to wait before this hop starts moving.
    delay: f32,
    t: f32,
    failed: bool,
}

/// Tails a growing log by BYTE OFFSET.
///
/// The first version counted LINES inside a fixed-size tail window, which works
/// right up until the file outgrows the window — after that the line count stops
/// increasing, "new lines" is permanently empty and the map silently freezes.
/// `runs.jsonl` reached 286 KB against a 96 KB window, so the tab shipped
/// animating nothing at all. Offsets do not have that failure mode.
#[derive(Debug)]
struct LogTail {
    path: PathBuf,
    offset: u64,
    primed: bool,
}

impl LogTail {
    fn new(path: PathBuf) -> Self {
        Self {
            path,
            offset: 0,
            primed: false,
        }
    }

    /// `(lines, is_seed)`. The first call returns history to build the map from
    /// without animating it; later calls return only what was appended since.
    fn poll(&mut self) -> (Vec<String>, bool) {
        let Ok(file) = File::open(&self.path) else {
            return (Vec::new(), false);
        };
        let Ok(size) = file.metadata().map(|meta| meta.len()) else {
            return (Vec::new(), false);
        };
        // Truncated or rotated (0.7 archives usage.jsonl) — start over rather
        // than read from an offset past the end.
        if size < self.offset {
            self.offset = 0;
            self.primed = false;
        }
        if !self.primed {
            self.primed = true;
            let from = size.saturating_sub(SEED_BYTES);
            let (lines, end) = read_from(&self.path, from, from > 0);
            self.offset = end;
            return (lines, true);
        }
        if size == self.offset {
            return (Vec::new(), false);
        }
        let (lines, end) = read_from(&self.path, self.offset, false);
        self.offset = end;
        (lines, false)
    }
}

/// Reads whole lines from `from` to EOF.
///
/// Returns the offset of the last complete line so a half-written record is
/// re-read next time instead of being parsed as garbage — these files are
/// appended to by other processes while we read them. `skip_first` drops the
/// line that a mid-file seek almost certainly cut in half.
fn read_from(path: &Path, from: u64, skip_first: bool) -> (Vec<String>, u64) {
    let Ok(mut file) = File::open(path) else {
        return (Vec::new(), from);
    };
    if file.seek(SeekFrom::Start(from)).is_err() {
        return (Vec::new(), from);
    }
    let mut buffer = Vec::new();
    if file.read_to_end(&mut buffer).is_err() {
        return (Vec::new(), from);
    }
    // Stop at the last newline: everything after it may still be being written.
    let complete = match buffer.iter().rposition(|byte| *byte == b'\n') {
        Some(index) => index + 1,
        None => return (Vec::new(), from),
    };
    let text = String::from_utf8_lossy(&buffer[..complete]);
    let mut lines: Vec<String> = text
        .lines()
        .map(|line| line.trim().trim_start_matches('\u{feff}').to_string())
        .filter(|line| !line.is_empty())
        .collect();
    if skip_first && !lines.is_empty() {
        lines.remove(0);
    }
    (lines, from + complete as u64)
}

pub struct ThinkingView {
    nodes: Vec<Node>,
    index: HashMap<(Stage, String), usize>,
    edges: HashMap<(usize, usize), Edge>,
    pulses: Vec<Pulse>,
    router_tail: LogTail,
    usage_tail: LogTail,
    runs_tail: LogTail,
    last_poll: Instant,
    last_frame: Instant,
    recent: HashMap<Stage, usize>,
    /// Clicked node: keeps a path highlighted while the user reads it.
    pinned: Option<usize>,
    pub events_seen: u64,
}

impl Default for ThinkingView {
    fn default() -> Self {
        let home = runtime_home_dir();
        Self {
            nodes: Vec::new(),
            index: HashMap::new(),
            edges: HashMap::new(),
            pulses: Vec::new(),
            router_tail: LogTail::new(home.join("router-decisions.jsonl")),
            usage_tail: LogTail::new(home.join("usage.jsonl")),
            runs_tail: LogTail::new(home.join("runs.jsonl")),
            last_poll: Instant::now() - POLL_INTERVAL,
            last_frame: Instant::now(),
            recent: HashMap::new(),
            pinned: None,
            events_seen: 0,
        }
    }
}

impl ThinkingView {
    fn node_id(&mut self, stage: Stage, label: &str, detail: &str) -> usize {
        let key = (stage, label.to_string());
        if let Some(&id) = self.index.get(&key) {
            if !detail.is_empty() {
                self.nodes[id].detail = detail.to_string();
            }
            return id;
        }
        let id = self.nodes.len();
        self.nodes.push(Node {
            stage,
            label: label.to_string(),
            detail: detail.to_string(),
            hits: 0,
            glow: 0.0,
            pos: egui::Pos2::ZERO,
            failed: false,
            visible: true,
        });
        self.index.insert(key, id);
        id
    }

    /// Registers a hit and links it to the nearest earlier stage that fired.
    /// `hop` staggers the pulse so one event cascades across the map.
    fn touch(
        &mut self,
        stage: Stage,
        label: &str,
        detail: &str,
        failed: bool,
        animate: bool,
        now: f64,
        hop: usize,
    ) {
        let id = self.node_id(stage, label, detail);
        self.nodes[id].hits += 1;
        self.nodes[id].failed = failed;

        let previous = Stage::ALL
            .iter()
            .filter(|candidate| **candidate < stage)
            .rev()
            .find_map(|candidate| self.recent.get(candidate).copied());

        if let Some(from) = previous {
            let edge = self.edges.entry((from, id)).or_insert(Edge {
                hits: 0,
                last_used: now,
                first_seen: now,
            });
            edge.hits += 1;
            edge.last_used = now;
            if animate {
                self.pulses.push(Pulse {
                    from,
                    to: id,
                    delay: hop as f32 * HOP_DELAY_SECS,
                    t: 0.0,
                    failed,
                });
            }
        }
        if animate {
            self.nodes[id].glow = 1.0;
            self.events_seen += 1;
        }
        self.recent.insert(stage, id);
    }

    fn ingest_router(&mut self, line: &str, animate: bool, now: f64) {
        let Ok(row) = serde_json::from_str::<RouterLine>(line) else {
            return;
        };
        let client = if row.client.is_empty() {
            "cli".to_string()
        } else {
            row.client.clone()
        };
        let source_detail = match client.as_str() {
            "ide" => "агент IDE через ai-delegate.cmd",
            "core" => "панель Delegator",
            _ => "командная строка",
        };
        self.touch(
            Stage::Source,
            &client,
            source_detail,
            false,
            animate,
            now,
            0,
        );

        let tier = if row.tier.is_empty() {
            "rules".to_string()
        } else {
            row.tier.clone()
        };
        let tier_label = match tier.as_str() {
            "rules" => "правила",
            "model" | "tier2" => "быстрая модель (2-й ярус)",
            "fallback" => "запасной путь",
            other => other,
        };
        let detail = format!(
            "уверенность {:.2}, решение за {} мс",
            row.confidence, row.route_ms
        );
        self.touch(Stage::Router, tier_label, &detail, false, animate, now, 1);

        if !row.mode.is_empty() {
            let why = if row.reason.is_empty() {
                "правило не названо".to_string()
            } else {
                format!("правило: {}", row.reason)
            };
            self.touch(Stage::Mode, &row.mode, &why, false, animate, now, 2);
        }
    }

    fn ingest_usage(&mut self, line: &str, animate: bool, now: f64) {
        let Ok(row) = serde_json::from_str::<UsageLine>(line) else {
            return;
        };
        let failed = matches!(row.ok, Some(false));

        if !row.client.is_empty() {
            self.touch(Stage::Source, &row.client, "", false, animate, now, 0);
        }
        if !row.mode.is_empty() {
            self.touch(Stage::Mode, &row.mode, "", false, animate, now, 1);
        }
        if !row.stage.is_empty() {
            let tokens = row.total_tokens.unwrap_or(0);
            let detail = if tokens > 0 {
                format!("{} ток., {:.1} с", tokens, row.elapsed_ms as f32 / 1000.0)
            } else {
                "внутренняя стадия".to_string()
            };
            let label = process_label(&row.stage).to_string();
            self.touch(Stage::Process, &label, &detail, failed, animate, now, 2);
        }
        if !row.provider.is_empty() {
            self.touch(Stage::Channel, &row.provider, "", failed, animate, now, 3);
        }
        if !row.model.is_empty() {
            let rating = crate::gui::opencode_setup::model_rating(&row.model)
                .map(|dpr| format!("рейтинг {dpr}"))
                .unwrap_or_else(|| "рейтинг неизвестен".to_string());
            self.touch(Stage::Model, &row.model, &rating, failed, animate, now, 4);
        }
        let (label, detail) = if failed {
            ("сбой", "вызов не дал ответа")
        } else {
            ("готово", "ответ получен")
        };
        self.touch(Stage::Outcome, label, detail, failed, animate, now, 5);
    }

    fn ingest_run(&mut self, line: &str, animate: bool, now: f64) {
        let Ok(row) = serde_json::from_str::<RunLine>(line) else {
            return;
        };
        let failed = row.event == "attempt_failed" || row.status == "error";

        if !row.execution_path.is_empty() {
            let detail = if row.domain.is_empty() {
                "канал доставки".to_string()
            } else {
                format!("класс задачи: {}", row.domain)
            };
            self.touch(
                Stage::Channel,
                &row.execution_path,
                &detail,
                failed,
                animate,
                now,
                0,
            );
        }
        if !row.model.is_empty() {
            let rating = crate::gui::opencode_setup::model_rating(&row.model)
                .map(|dpr| format!("рейтинг {dpr}"))
                .unwrap_or_else(|| "рейтинг неизвестен".to_string());
            let detail = if row.elapsed_ms > 0 {
                format!("{rating}, {:.1} с", row.elapsed_ms as f32 / 1000.0)
            } else {
                rating
            };
            self.touch(Stage::Model, &row.model, &detail, failed, animate, now, 1);
        }

        // Only terminal events make an outcome: `started`/`attempt_started`
        // would otherwise light «готово» before anything had finished.
        match row.event.as_str() {
            "completed" => {
                self.touch(
                    Stage::Outcome,
                    "готово",
                    "ответ получен",
                    false,
                    animate,
                    now,
                    2,
                );
            }
            "attempt_failed" => {
                let label = if row.error_class.is_empty() {
                    "сбой".to_string()
                } else {
                    format!("сбой: {}", row.error_class)
                };
                self.touch(
                    Stage::Outcome,
                    &label,
                    "переход к следующей модели",
                    true,
                    animate,
                    now,
                    2,
                );
            }
            _ => {}
        }
    }

    fn poll_logs(&mut self, now: f64) {
        if self.last_poll.elapsed() < POLL_INTERVAL {
            return;
        }
        self.last_poll = Instant::now();

        let (router_lines, router_seed) = self.router_tail.poll();
        for line in router_lines {
            self.ingest_router(&line, !router_seed, now);
        }
        let (usage_lines, usage_seed) = self.usage_tail.poll();
        for line in usage_lines {
            self.ingest_usage(&line, !usage_seed, now);
        }
        let (run_lines, runs_seed) = self.runs_tail.poll();
        for line in run_lines {
            self.ingest_run(&line, !runs_seed, now);
        }
    }

    fn advance(&mut self, dt: f32) {
        for node in &mut self.nodes {
            node.glow = (node.glow - GLOW_DECAY_PER_SEC * dt).max(0.0);
        }
        for pulse in &mut self.pulses {
            if pulse.delay > 0.0 {
                pulse.delay -= dt;
            } else {
                pulse.t += PULSE_SPEED_PER_SEC * dt;
            }
        }
        self.pulses.retain(|pulse| pulse.t <= 1.0);
    }

    pub fn ui(&mut self, ui: &mut egui::Ui, theme: &ThemeConfig) {
        let now = ui.input(|input| input.time);
        let dt = self.last_frame.elapsed().as_secs_f32().min(0.25);
        self.last_frame = Instant::now();
        self.poll_logs(now);
        self.advance(dt);
        // Ambient motion needs frames even when nothing else changed.
        ui.ctx().request_repaint_after(Duration::from_millis(16));

        let available = ui.available_size();
        // Never clamp to a minimum ABOVE what is available: that is what pushed
        // the footer off the panel and truncated it in the first prototype.
        let map_height = (available.y - FOOTER_HEIGHT).max(120.0);
        let (response, painter) =
            ui.allocate_painter(egui::vec2(available.x, map_height), egui::Sense::click());
        let rect = response.rect;

        self.layout(rect);

        let hovered = response.hover_pos().and_then(|pos| self.node_at(pos));
        if response.clicked() {
            self.pinned = match (hovered, self.pinned) {
                (Some(id), Some(current)) if current == id => None,
                (Some(id), _) => Some(id),
                (None, _) => None,
            };
        }
        let focus = self.pinned.or(hovered);

        self.paint_edges(&painter, theme, now, focus);
        self.paint_nodes(&painter, theme, rect, focus);
        self.paint_footer(ui, theme, focus);
    }

    fn node_at(&self, pos: egui::Pos2) -> Option<usize> {
        self.nodes
            .iter()
            .enumerate()
            .filter(|(_, node)| node.visible)
            .find(|(_, node)| node.pos.distance(pos) <= node_radius(node) + 5.0)
            .map(|(id, _)| id)
    }

    /// Fixed columns; within a column the busiest nodes win the slots.
    fn layout(&mut self, rect: egui::Rect) {
        let columns = Stage::ALL.len() as f32;
        let margin_x = (rect.width() / (columns * 2.2)).min(64.0);
        let usable = rect.width() - margin_x * 2.0;
        let step = usable / (columns - 1.0).max(1.0);

        for node in &mut self.nodes {
            node.visible = false;
        }

        for stage in Stage::ALL {
            let mut members: Vec<usize> = self
                .nodes
                .iter()
                .enumerate()
                .filter(|(_, node)| node.stage == stage)
                .map(|(id, _)| id)
                .collect();
            if members.is_empty() {
                continue;
            }
            members.sort_by(|left, right| {
                self.nodes[*right]
                    .hits
                    .cmp(&self.nodes[*left].hits)
                    .then_with(|| self.nodes[*left].label.cmp(&self.nodes[*right].label))
            });
            members.truncate(MAX_NODES_PER_STAGE);

            let x = rect.left() + margin_x + step * (stage as usize as f32);
            let top = rect.top() + 44.0;
            // Room for the node's own caption AND the «+N ещё» marker below it.
            let bottom = rect.bottom() - 38.0;
            let span = (bottom - top).max(1.0);
            let count = members.len() as f32;
            for (slot, id) in members.into_iter().enumerate() {
                let y = if count <= 1.0 {
                    top + span / 2.0
                } else {
                    top + span * (slot as f32 / (count - 1.0))
                };
                self.nodes[id].pos = egui::pos2(x, y);
                self.nodes[id].visible = true;
            }
        }
    }

    /// True when the edge should stay bright under the current focus.
    fn in_focus(&self, focus: Option<usize>, from: usize, to: usize) -> bool {
        match focus {
            None => true,
            Some(id) => from == id || to == id,
        }
    }

    fn paint_edges(
        &self,
        painter: &egui::Painter,
        theme: &ThemeConfig,
        now: f64,
        focus: Option<usize>,
    ) {
        let accent = theme.accent_color();
        let success = theme.success_color();
        let error = theme.error_color();
        let weak = theme.weak_text_color();

        for (&(from, to), edge) in &self.edges {
            let (Some(a), Some(b)) = (self.nodes.get(from), self.nodes.get(to)) else {
                continue;
            };
            if !a.visible || !b.visible {
                continue;
            }
            let lit = self.in_focus(focus, from, to);
            let age = now - edge.last_used;
            let is_new = now - edge.first_seen < EDGE_NEW_SECS;
            let heat = if age < EDGE_HOT_SECS {
                1.0 - (age / EDGE_HOT_SECS) as f32
            } else {
                0.0
            };

            // Base line: always visible, so the SHAPE of the pipeline reads even
            // at rest — but never bright enough to compete with live traffic.
            let base_alpha = if lit { 30.0 + 90.0 * heat } else { 12.0 };
            let colour = if is_new { success } else { accent };
            painter.add(edge_shape(
                a.pos,
                b.pos,
                with_alpha(if lit { colour } else { weak }, base_alpha as u8),
                if is_new { 2.0 } else { 1.0 + heat },
            ));

            // Ambient particle: slow, dim and ALWAYS running. Its phase is
            // derived from the edge identity so neighbouring edges do not march
            // in lockstep.
            if lit {
                let phase = ((now * 0.11) + edge_phase(from, to)).rem_euclid(1.0) as f32;
                let point = bezier_point(a.pos, b.pos, phase);
                let alpha = (34.0 + 120.0 * heat) as u8;
                painter.circle_filled(point, 1.8 + 1.4 * heat, with_alpha(colour, alpha));
            }
        }

        // Live pulses ride on top of everything.
        for pulse in &self.pulses {
            if pulse.delay > 0.0 {
                continue;
            }
            let (Some(a), Some(b)) = (self.nodes.get(pulse.from), self.nodes.get(pulse.to)) else {
                continue;
            };
            if !a.visible || !b.visible || !self.in_focus(focus, pulse.from, pulse.to) {
                continue;
            }
            let colour = if pulse.failed { error } else { accent };
            let t = pulse.t.clamp(0.0, 1.0);
            let fade = ((1.0 - t) * 235.0) as u8;
            painter.add(edge_shape(a.pos, b.pos, with_alpha(colour, fade), 2.2));
            // A short comet tail makes the direction of travel unambiguous.
            for (step, trail) in [(0.0, 5.0), (-0.045, 3.4), (-0.09, 2.1)] {
                let point = bezier_point(a.pos, b.pos, (t + step).clamp(0.0, 1.0));
                let alpha = (235.0 * (1.0 + step * 8.0).max(0.25)) as u8;
                painter.circle_filled(point, trail, with_alpha(colour, alpha));
            }
        }
    }

    fn paint_nodes(
        &self,
        painter: &egui::Painter,
        theme: &ThemeConfig,
        rect: egui::Rect,
        focus: Option<usize>,
    ) {
        for stage in Stage::ALL {
            let Some(node) = self.nodes.iter().find(|n| n.stage == stage && n.visible) else {
                continue;
            };
            painter.text(
                egui::pos2(node.pos.x, rect.top() + 13.0),
                egui::Align2::CENTER_CENTER,
                stage.title(),
                egui::FontId::proportional(12.0),
                theme.weak_text_color(),
            );
            let hidden = self.nodes.iter().filter(|n| n.stage == stage).count()
                - self
                    .nodes
                    .iter()
                    .filter(|n| n.stage == stage && n.visible)
                    .count();
            if hidden > 0 {
                painter.text(
                    egui::pos2(node.pos.x, rect.bottom() - 10.0),
                    egui::Align2::CENTER_CENTER,
                    format!("+{hidden} ещё"),
                    egui::FontId::proportional(10.0),
                    theme.weak_text_color(),
                );
            }
        }

        for (id, node) in self.nodes.iter().enumerate() {
            if !node.visible {
                continue;
            }
            let lit = match focus {
                None => true,
                Some(target) => {
                    target == id
                        || self.edges.keys().any(|(from, to)| {
                            (*from == target && *to == id) || (*to == target && *from == id)
                        })
                }
            };
            let base = if node.failed {
                theme.error_color()
            } else {
                theme.accent_color()
            };
            let radius = node_radius(node);

            if node.glow > 0.01 && lit {
                painter.circle_filled(
                    node.pos,
                    radius + 12.0 * node.glow,
                    with_alpha(base, (80.0 * node.glow) as u8),
                );
            }
            let fill_alpha = if lit { 55.0 + 170.0 * node.glow } else { 18.0 };
            painter.circle_filled(node.pos, radius, with_alpha(base, fill_alpha as u8));
            painter.circle_stroke(
                node.pos,
                radius,
                egui::Stroke::new(
                    if focus == Some(id) { 2.2 } else { 1.2 },
                    with_alpha(base, if lit { 235 } else { 60 }),
                ),
            );
            painter.text(
                egui::pos2(node.pos.x, node.pos.y + radius + 9.0),
                egui::Align2::CENTER_CENTER,
                short_label(&node.label),
                egui::FontId::proportional(11.0),
                if !lit {
                    with_alpha(theme.weak_text_color(), 70)
                } else if node.glow > 0.05 {
                    theme.success_color()
                } else {
                    theme.weak_text_color()
                },
            );
        }
    }

    /// Fixed strip, so this text can never be pushed off the panel.
    fn paint_footer(&self, ui: &mut egui::Ui, theme: &ThemeConfig, focus: Option<usize>) {
        ui.add_space(4.0);
        match focus.and_then(|id| self.nodes.get(id)) {
            Some(node) => {
                ui.label(
                    egui::RichText::new(format!("{} — {}", node.label, node.detail))
                        .color(theme.accent_color()),
                );
                ui.colored_label(
                    theme.weak_text_color(),
                    format!(
                        "обращений: {} · {} · клик снимает выделение",
                        node.hits,
                        node.stage.title().to_lowercase()
                    ),
                );
            }
            None if self.nodes.is_empty() => {
                ui.colored_label(
                    theme.weak_text_color(),
                    "Пока пусто: карта заполнится, как только агент обратится к Delegator.",
                );
            }
            None => {
                ui.colored_label(
                    theme.weak_text_color(),
                    "Наведите на узел — подсветится его путь; клик закрепляет выделение.",
                );
                ui.colored_label(
                    theme.weak_text_color(),
                    format!(
                        "узлов {}, связей {}, событий за сеанс {} · зелёная связь — новая · красная — сбой · здесь только процессы, без текста задач и ответов",
                        self.nodes.iter().filter(|n| n.visible).count(),
                        self.edges.len(),
                        self.events_seen
                    ),
                );
            }
        }
    }
}

fn with_alpha(colour: egui::Color32, alpha: u8) -> egui::Color32 {
    egui::Color32::from_rgba_unmultiplied(colour.r(), colour.g(), colour.b(), alpha)
}

/// Busier nodes are bigger, but logarithmically — a model with 400 hits must
/// not swallow its column.
fn node_radius(node: &Node) -> f32 {
    let growth = (node.hits as f32).max(1.0).ln();
    (7.0 + growth * 1.4).clamp(7.0, 15.0)
}

/// Deterministic per-edge phase offset in 0..1, so ambient particles do not
/// march in lockstep. Any stable spread will do; this is not randomness.
fn edge_phase(from: usize, to: usize) -> f64 {
    let mixed = (from.wrapping_mul(2_654_435_761) ^ to.wrapping_mul(40_503)) % 1000;
    mixed as f64 / 1000.0
}

/// Model ids get long (`huggingface/deepseek-ai/DeepSeek-V4-Pro`); the map shows
/// the distinctive tail and the footer carries the rest.
fn short_label(label: &str) -> String {
    let tail = label.rsplit('/').next().unwrap_or(label);
    if tail.chars().count() > 20 {
        let clipped: String = tail.chars().take(19).collect();
        format!("{clipped}…")
    } else {
        tail.to_string()
    }
}

/// Horizontal-tangent cubic between two columns: the "neural" look comes from
/// the curve, not from a texture.
fn control_points(from: egui::Pos2, to: egui::Pos2) -> [egui::Pos2; 4] {
    let reach = ((to.x - from.x) * 0.45).abs().max(24.0);
    [
        from,
        egui::pos2(from.x + reach, from.y),
        egui::pos2(to.x - reach, to.y),
        to,
    ]
}

fn edge_shape(from: egui::Pos2, to: egui::Pos2, colour: egui::Color32, width: f32) -> egui::Shape {
    egui::Shape::CubicBezier(egui::epaint::CubicBezierShape::from_points_stroke(
        control_points(from, to),
        false,
        egui::Color32::TRANSPARENT,
        egui::Stroke::new(width, colour),
    ))
}

/// Position along the same cubic, so every dot rides exactly the drawn line.
fn bezier_point(from: egui::Pos2, to: egui::Pos2, t: f32) -> egui::Pos2 {
    let [p0, p1, p2, p3] = control_points(from, to);
    let u = 1.0 - t;
    let x = u * u * u * p0.x + 3.0 * u * u * t * p1.x + 3.0 * u * t * t * p2.x + t * t * t * p3.x;
    let y = u * u * u * p0.y + 3.0 * u * u * t * p1.y + 3.0 * u * t * t * p2.y + t * t * t * p3.y;
    egui::pos2(x, y)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_log(name: &str, body: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("delegator-thinking-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("log.jsonl");
        std::fs::write(&path, body).expect("write log");
        path
    }

    /// The bug this file shipped with. The first version counted LINES inside a
    /// fixed byte window, so once the log outgrew the window the count stopped
    /// growing and "new lines" was empty forever — a permanently frozen map.
    #[test]
    fn a_log_far_larger_than_the_seed_window_still_reports_new_lines() {
        let mut body = String::new();
        for index in 0..12_000 {
            body.push_str(&format!("{{\"event\":\"completed\",\"n\":{index}}}\n"));
        }
        assert!(
            body.len() as u64 > SEED_BYTES * 2,
            "the fixture must exceed the seed window"
        );
        let path = temp_log("outgrown", &body);
        let mut tail = LogTail::new(path.clone());

        let (seed, is_seed) = tail.poll();
        assert!(is_seed);
        assert!(!seed.is_empty(), "the seed must populate the map");

        // Nothing appended yet.
        assert_eq!(tail.poll().0.len(), 0);

        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .expect("append");
        writeln!(file, "{{\"event\":\"completed\",\"n\":99999}}").expect("write");
        drop(file);

        let (fresh, is_seed) = tail.poll();
        assert!(!is_seed);
        assert_eq!(fresh.len(), 1, "an appended line must be seen");
        assert!(fresh[0].contains("99999"));

        let _ = std::fs::remove_dir_all(path.parent().expect("dir"));
    }

    /// These files are appended to by other processes while we read them.
    #[test]
    fn a_half_written_trailing_line_is_not_parsed_until_it_is_complete() {
        let path = temp_log("partial", "{\"event\":\"completed\"}\n");
        let mut tail = LogTail::new(path.clone());
        let _ = tail.poll();

        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .expect("append");
        write!(file, "{{\"event\":\"comp").expect("write");
        drop(file);
        assert_eq!(tail.poll().0.len(), 0, "a partial line must be held back");

        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .expect("append");
        writeln!(file, "leted\"}}").expect("write");
        drop(file);
        let (fresh, _) = tail.poll();
        assert_eq!(fresh.len(), 1);
        assert_eq!(fresh[0], "{\"event\":\"completed\"}");

        let _ = std::fs::remove_dir_all(path.parent().expect("dir"));
    }

    /// 0.7 renames usage.jsonl on upgrade; a shrinking file must not leave the
    /// reader seeking past the end forever.
    #[test]
    fn a_truncated_log_restarts_instead_of_reading_past_the_end() {
        let path = temp_log(
            "truncated",
            "{\"event\":\"completed\",\"n\":1}\n".repeat(50).as_str(),
        );
        let mut tail = LogTail::new(path.clone());
        let _ = tail.poll();
        assert!(tail.offset > 0);

        std::fs::write(&path, "{\"event\":\"completed\",\"n\":2}\n").expect("truncate");
        let (lines, is_seed) = tail.poll();
        assert!(is_seed, "a shrunk file is treated as a fresh log");
        assert_eq!(lines.len(), 1);

        let _ = std::fs::remove_dir_all(path.parent().expect("dir"));
    }

    /// The whole privacy claim of this tab in one test: feed it records that DO
    /// carry task and answer text and prove none of it can be reached.
    #[test]
    fn chat_content_is_structurally_unreachable() {
        let run = r#"{"runId":"r1","delegate":"opencode","event":"completed","status":"ok",
            "domain":"code_debug","model":"opencode/hy3-free","executionPath":"opencode-cli",
            "tokens":7762,"elapsedMs":6727,
            "promptSummary":"СЕКРЕТ: перепиши мой приватный ключ",
            "outputPreview":"вот ваш приватный ключ ...",
            "errorPreview":"secret error text"}"#;
        let mut view = ThinkingView::default();
        view.ingest_run(run, true, 1.0);
        let haystack: String = view
            .nodes
            .iter()
            .map(|node| format!("{} {}", node.label, node.detail))
            .collect::<Vec<_>>()
            .join(" | ");
        assert!(!haystack.contains("СЕКРЕТ"), "{haystack}");
        assert!(!haystack.contains("приватный"), "{haystack}");
        assert!(!haystack.contains("secret"), "{haystack}");
        assert!(haystack.contains("opencode/hy3-free"));
    }

    /// usage.jsonl is what makes the «Процесс» column real: triage, advisors and
    /// synthesis were invisible before, and triage alone turned out to be 45 %
    /// of one session's spend.
    #[test]
    fn usage_records_expose_the_internal_stages() {
        let mut view = ThinkingView::default();
        view.ingest_usage(
            r#"{"client":"ide","stage":"triage","mode":"ask","provider":"opencode-cli",
                "model":"opencode/hy3-free","totalTokens":4770,"elapsedMs":2100,"ok":true}"#,
            true,
            1.0,
        );
        let process = view
            .nodes
            .iter()
            .find(|node| node.stage == Stage::Process)
            .expect("process node");
        assert_eq!(process.label, "триаж");
        assert!(process.detail.contains("4770"));
        // Source → Mode → Process → Channel → Model → Outcome: five edges.
        assert_eq!(view.edges.len(), 5);
        assert!(view.pulses.len() >= 5);
    }

    /// Hops must be staggered, or one event lights every column in the same
    /// frame and reads as a flash instead of a flow.
    #[test]
    fn one_event_cascades_across_the_map_instead_of_flashing_at_once() {
        let mut view = ThinkingView::default();
        view.ingest_router(
            r#"{"mode":"delegate","client":"ide","tier":"rules","reason":"code-task",
                "confidence":0.8,"routeMs":1338}"#,
            true,
            1.0,
        );
        let delays: Vec<f32> = view.pulses.iter().map(|pulse| pulse.delay).collect();
        assert_eq!(delays.len(), 2);
        assert!(
            delays[1] > delays[0],
            "later hops must start later: {delays:?}"
        );
        // The rule name reaches the map; nothing else from the record does.
        let mode = view
            .nodes
            .iter()
            .find(|node| node.stage == Stage::Mode)
            .expect("mode node");
        assert_eq!(mode.detail, "правило: code-task");
    }

    #[test]
    fn a_failed_attempt_is_marked_and_a_start_event_is_not_an_outcome() {
        let mut view = ThinkingView::default();
        view.ingest_run(
            r#"{"event":"attempt_started","status":"running","model":"opencode/big-pickle"}"#,
            true,
            1.0,
        );
        assert!(
            !view.nodes.iter().any(|node| node.stage == Stage::Outcome),
            "a started attempt must not light up an outcome"
        );
        view.ingest_run(
            r#"{"event":"attempt_failed","status":"error","model":"opencode/big-pickle",
                "errorClass":"quota_or_rate_limited"}"#,
            true,
            1.0,
        );
        let outcome = view
            .nodes
            .iter()
            .find(|node| node.stage == Stage::Outcome)
            .expect("outcome node");
        assert_eq!(outcome.label, "сбой: quota_or_rate_limited");
        assert!(outcome.failed);
    }

    /// A crowded column must fold, not shrink into unreadable slivers.
    #[test]
    fn a_crowded_column_keeps_the_busiest_nodes_and_folds_the_rest() {
        let mut view = ThinkingView::default();
        for index in 0..(MAX_NODES_PER_STAGE + 4) {
            let model = format!("opencode/m{index}-free");
            for _ in 0..=index {
                view.ingest_run(
                    &format!(r#"{{"event":"completed","status":"ok","model":"{model}"}}"#),
                    false,
                    1.0,
                );
            }
        }
        view.layout(egui::Rect::from_min_size(
            egui::pos2(0.0, 0.0),
            egui::vec2(1200.0, 600.0),
        ));
        let shown = view
            .nodes
            .iter()
            .filter(|node| node.stage == Stage::Model && node.visible)
            .count();
        assert_eq!(shown, MAX_NODES_PER_STAGE);
        // The busiest survived, the quietest folded away.
        let busiest = view
            .nodes
            .iter()
            .find(|node| {
                node.label
                    .contains(&format!("m{}-free", MAX_NODES_PER_STAGE + 3))
            })
            .expect("busiest node");
        assert!(busiest.visible);
        let quietest = view
            .nodes
            .iter()
            .find(|node| node.label == "opencode/m0-free")
            .expect("quietest node");
        assert!(!quietest.visible);
    }

    #[test]
    fn long_model_ids_are_shortened_to_the_distinctive_tail() {
        assert_eq!(short_label("opencode/hy3-free"), "hy3-free");
        assert_eq!(
            short_label("huggingface/deepseek-ai/DeepSeek-V4-Pro"),
            "DeepSeek-V4-Pro"
        );
        assert!(short_label(&format!("x/{}", "a".repeat(40))).ends_with('…'));
    }

    /// Dots must ride the curve that is actually drawn, or they drift off the
    /// line at the ends.
    #[test]
    fn the_pulse_follows_the_drawn_curve_end_to_end() {
        let from = egui::pos2(10.0, 10.0);
        let to = egui::pos2(210.0, 90.0);
        assert_eq!(bezier_point(from, to, 0.0), from);
        assert_eq!(bezier_point(from, to, 1.0), to);
        let mid = bezier_point(from, to, 0.5);
        assert!(mid.x > from.x && mid.x < to.x);
        assert!((mid.y - 50.0).abs() < 0.01, "{mid:?}");
    }

    /// Ambient particles must not march in lockstep, or the map looks like a
    /// metronome instead of a network.
    #[test]
    fn ambient_phases_are_spread_across_edges() {
        let phases: Vec<f64> = (0..12).map(|index| edge_phase(index, index + 1)).collect();
        let distinct = phases
            .iter()
            .map(|value| (value * 100.0) as i64)
            .collect::<std::collections::HashSet<_>>();
        assert!(distinct.len() >= 8, "{phases:?}");
        assert!(phases.iter().all(|value| (0.0..1.0).contains(value)));
    }
}
