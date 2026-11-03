//! «Мышление» — a live tree of what Delegator is doing right now.
//!
//! Every delegation is one ROW of the map. The request is the root, the router's
//! decision is the first branch, each model call is a branch from the router to a
//! model node, and a call that answered converges into the answer node on the
//! right. The map shows only what a record says happened: no branch exists without
//! a record, and the durations on the nodes are the logged `elapsedMs`.
//!
//! Two sources, joined by `requestId` (both files carry it):
//!   `router-decisions.jsonl` — client, tier, mode and the RULE that fired
//!   `usage.jsonl`            — one record per model call: stage, model, outcome
//!
//! `runs.jsonl` is not read. Its records carry a `runId`, not the `requestId`, so
//! they cannot be placed in a row.
//!
//! The record structs below have NO field for prompt, output or error text, so the
//! text of a task or an answer cannot reach this module: serde drops what it was
//! never asked for. A test feeds such text and proves that it cannot surface.

use crate::config::runtime_home_dir;
use crate::theme::ThemeConfig;
use eframe::egui;
use serde::Deserialize;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How often the logs are re-read. Only while the tab is on screen: a hidden
/// window gets no paint messages, so nothing polls from the tray.
const POLL_INTERVAL: Duration = Duration::from_millis(600);

/// Bytes of history read on the first poll.
const SEED_BYTES: u64 = 128 * 1024;

/// Reserved strip under the map, so the hover line is never pushed off the panel.
const FOOTER_HEIGHT: f32 = 58.0;

/// Rows on screen, newest first. Older delegations are dropped, not squeezed.
const MAX_ROWS: usize = 6;

/// Branches drawn per row. The OLDEST beyond this fold into a «+N ещё» marker,
/// so the newest attempts — the ones that matter now — always stay visible.
const MAX_ATTEMPTS_PER_ROW: usize = 4;

/// Bound on calls kept per request, so one endless request cannot grow forever.
const MAX_ATTEMPTS_KEPT: usize = 64;

/// Bound on requests kept in memory.
const MAX_TRACES: usize = 200;

const ROW_MIN: f32 = 56.0;
const ROW_MAX: f32 = 110.0;

/// Seconds a branch takes to reveal itself after its record arrives. The record is
/// written when the call ENDS, so the reveal is an animation, not the real duration;
/// the real duration is printed on the node.
const GROW_SECS: f64 = 0.9;

/// Seconds a result pulse needs to travel from its model node to the answer.
const PULSE_SECS: f64 = 1.1;

/// A request with a successful call is finished once no record has arrived for this long.
/// A later record reopens it, so a stage still running can make this flicker — by design.
const DONE_QUIET_SECS: f64 = 3.0;

/// A request whose calls all failed gets this long for the next fallback to report.
const FAIL_QUIET_SECS: f64 = 20.0;

/// A request that routed but has no call record yet is given up after this long.
const STALE_SECS: f64 = 400.0;

/// Finished rows fade over this long, then leave the map.
const FADE_SECS: f64 = 60.0;

/// Repaint cadence while something is moving, and while only the logs are watched.
const ACTIVE_REPAINT: Duration = Duration::from_millis(50);
const IDLE_REPAINT: Duration = Duration::from_millis(1000);

/// Router decision. `reason` is a fixed rule name (`code-task`, `keep-trivial`, …)
/// chosen from a closed set in router.py — never user text.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct RouterLine {
    #[serde(rename = "requestId")]
    request_id: String,
    client: String,
    mode: String,
    tier: String,
    reason: String,
    confidence: f32,
    #[serde(rename = "routeMs")]
    route_ms: u64,
}

/// One model call. `errorClass` is a closed set (timeout, network, auth, …).
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct UsageLine {
    #[serde(rename = "requestId")]
    request_id: String,
    client: String,
    stage: String,
    mode: String,
    provider: String,
    model: String,
    #[serde(rename = "elapsedMs")]
    elapsed_ms: u64,
    ok: Option<bool>,
    #[serde(rename = "errorClass")]
    error_class: String,
}

/// Where a request stands. Derived from its records, never stored by the producer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Running,
    Done,
    Failed,
}

/// One model call inside a request.
#[derive(Debug, Clone)]
struct Attempt {
    stage: String,
    model: String,
    provider: String,
    elapsed_ms: u64,
    failed: bool,
    error_class: String,
    /// When the record was seen. The reveal animation starts here.
    born: f64,
}

/// One delegation: a row of the map.
#[derive(Debug, Clone)]
struct Trace {
    id: String,
    client: String,
    mode: String,
    tier: String,
    reason: String,
    confidence: f32,
    route_ms: u64,
    started: f64,
    last_record: f64,
    attempts: Vec<Attempt>,
    phase: Phase,
    finished_at: Option<f64>,
}

impl Trace {
    fn has_success(&self) -> bool {
        self.attempts.iter().any(|attempt| !attempt.failed)
    }
}

/// What the pointer can hover or click, inside one row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Part {
    Root,
    Router,
    Attempt(usize),
    Answer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Hit {
    trace: usize,
    part: Part,
}

/// Screen positions of one row, rebuilt every frame from the traces.
struct RowLayout {
    trace: usize,
    root: egui::Pos2,
    router: egui::Pos2,
    answer: egui::Pos2,
    /// `(index into Trace::attempts, position)` for the branches drawn.
    attempts: Vec<(usize, egui::Pos2)>,
    /// Older calls folded into the «+N ещё» marker.
    folded: usize,
    fold_mark: egui::Pos2,
}

/// Russian names for the internal stages, so a branch reads as a process.
fn process_label(stage: &str) -> &str {
    match stage {
        "answer" => "ответ",
        "triage" => "триаж",
        "extract" => "выжимка контекста",
        "advisor" => "советник",
        "synthesis" => "синтез",
        "critic" => "критик",
        "verify" => "проверка",
        "review" => "разбор черновика",
        "improve" => "правка черновика",
        "micro" => "микро-задача",
        "plan" => "план",
        "parallel" => "параллельно",
        "route" => "выбор режима",
        other => other,
    }
}

fn tier_label(tier: &str) -> &str {
    match tier {
        "" | "rules" => "правила",
        "model" | "tier2" => "быстрая модель",
        "fallback" => "запасной путь",
        other => other,
    }
}

fn client_label(client: &str) -> &str {
    match client {
        "ide" => "IDE",
        "core" => "панель",
        "" | "cli" => "CLI",
        other => other,
    }
}

/// The distinctive tail of a model id, cut to a width that fits beside a node.
fn short_label(label: &str) -> String {
    let tail = label.rsplit('/').next().unwrap_or(label);
    if tail.chars().count() <= 24 {
        tail.to_string()
    } else {
        format!("{}…", tail.chars().take(23).collect::<String>())
    }
}

fn short_id(id: &str) -> String {
    id.chars().take(8).collect()
}

fn with_alpha(colour: egui::Color32, alpha: u8) -> egui::Color32 {
    egui::Color32::from_rgba_unmultiplied(colour.r(), colour.g(), colour.b(), alpha)
}

/// Alpha from a base value scaled by a 0..1 level.
fn alpha(base: f32, level: f32) -> u8 {
    (base * level).clamp(0.0, 255.0) as u8
}

/// How far a branch has revealed itself, 0..1.
fn grow(now: f64, born: f64) -> f32 {
    ((now - born) / GROW_SECS).clamp(0.0, 1.0) as f32
}

fn fade_factor(trace: &Trace, now: f64) -> f32 {
    match trace.finished_at {
        Some(done) => (1.0 - (now - done) / FADE_SECS).clamp(0.25, 1.0) as f32,
        None => 1.0,
    }
}

/// Seeded history is placed before the reveal window, so it appears settled and
/// does not replay as if it were happening now.
fn event_time(live: bool, now: f64) -> f64 {
    if live {
        now
    } else {
        now - GROW_SECS - PULSE_SECS - 1.0
    }
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
    traces: Vec<Trace>,
    router_tail: LogTail,
    usage_tail: LogTail,
    last_poll: Instant,
    /// Clicked branch: keeps its row highlighted while the user reads it.
    pinned: Option<Hit>,
    pub events_seen: u64,
}

impl Default for ThinkingView {
    fn default() -> Self {
        let home = runtime_home_dir();
        Self {
            traces: Vec::new(),
            router_tail: LogTail::new(home.join("router-decisions.jsonl")),
            usage_tail: LogTail::new(home.join("usage.jsonl")),
            last_poll: Instant::now() - POLL_INTERVAL,
            pinned: None,
            events_seen: 0,
        }
    }
}

impl ThinkingView {
    fn trace_index(&mut self, request_id: &str, client: &str, at: f64) -> usize {
        if let Some(index) = self.traces.iter().position(|trace| trace.id == request_id) {
            return index;
        }
        if self.traces.len() >= MAX_TRACES {
            self.traces.remove(0);
            self.pinned = None;
        }
        self.traces.push(Trace {
            id: request_id.to_string(),
            client: client.to_string(),
            mode: String::new(),
            tier: String::new(),
            reason: String::new(),
            confidence: 0.0,
            route_ms: 0,
            started: at,
            last_record: at,
            attempts: Vec::new(),
            phase: Phase::Running,
            finished_at: None,
        });
        self.traces.len() - 1
    }

    fn ingest_router(&mut self, line: &str, live: bool, now: f64) {
        let Ok(row) = serde_json::from_str::<RouterLine>(line) else {
            return;
        };
        if row.request_id.is_empty() {
            return;
        }
        let at = event_time(live, now);
        let index = self.trace_index(&row.request_id, &row.client, at);
        let trace = &mut self.traces[index];
        if trace.client.is_empty() {
            trace.client = row.client;
        }
        trace.mode = row.mode;
        trace.tier = row.tier;
        trace.reason = row.reason;
        trace.confidence = row.confidence;
        trace.route_ms = row.route_ms;
        if live {
            self.events_seen += 1;
        }
    }

    /// A call record. A record arriving after a finish reopens the request: a
    /// fallback or the next stage is still running.
    fn ingest_usage(&mut self, line: &str, live: bool, now: f64) {
        let Ok(row) = serde_json::from_str::<UsageLine>(line) else {
            return;
        };
        if row.request_id.is_empty() {
            return;
        }
        let at = event_time(live, now);
        let index = self.trace_index(&row.request_id, &row.client, at);
        let trace = &mut self.traces[index];
        if trace.mode.is_empty() {
            trace.mode = row.mode.clone();
        }
        if trace.attempts.len() < MAX_ATTEMPTS_KEPT {
            trace.attempts.push(Attempt {
                stage: if row.stage.is_empty() {
                    "вызов".to_string()
                } else {
                    process_label(&row.stage).to_string()
                },
                model: row.model,
                provider: row.provider,
                elapsed_ms: row.elapsed_ms,
                failed: row.ok == Some(false),
                error_class: row.error_class,
                born: at,
            });
        }
        trace.last_record = at;
        trace.phase = Phase::Running;
        trace.finished_at = None;
        if live {
            self.events_seen += 1;
        }
    }

    /// Derives each request's phase from how long it has been quiet.
    fn settle(&mut self, now: f64) {
        for trace in self
            .traces
            .iter_mut()
            .filter(|trace| trace.phase == Phase::Running)
        {
            let quiet = now - trace.last_record;
            let next = if trace.attempts.is_empty() {
                (quiet >= STALE_SECS).then_some(Phase::Failed)
            } else if trace.has_success() {
                (quiet >= DONE_QUIET_SECS).then_some(Phase::Done)
            } else {
                (quiet >= FAIL_QUIET_SECS).then_some(Phase::Failed)
            };
            if let Some(phase) = next {
                trace.phase = phase;
                trace.finished_at = Some(now);
            }
        }
    }

    fn prune(&mut self, now: f64) {
        let before = self.traces.len();
        self.traces.retain(|trace| match trace.finished_at {
            Some(done) => now - done < FADE_SECS,
            None => true,
        });
        if self.traces.len() != before {
            self.pinned = None;
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
        if router_seed || usage_seed {
            // History cannot say whether a request that never got a call record is
            // still running, so it is not shown as running.
            for trace in self
                .traces
                .iter_mut()
                .filter(|trace| trace.phase == Phase::Running && trace.attempts.is_empty())
            {
                trace.phase = Phase::Failed;
                trace.finished_at = Some(now);
            }
        }
        self.settle(now);
        self.prune(now);
    }

    /// True while a branch is revealing, a pulse is travelling, or a request is open.
    /// Otherwise the map is still and only the log poll keeps the tab alive.
    fn animating(&self, now: f64) -> bool {
        self.traces.iter().any(|trace| {
            trace.phase == Phase::Running
                || now - trace.started < GROW_SECS
                || trace
                    .attempts
                    .iter()
                    .any(|attempt| now - attempt.born < GROW_SECS + PULSE_SECS)
        })
    }

    /// Newest row at the top. Positions depend only on the traces and the rect, so
    /// the layout is stable: nothing moves unless a record changes it.
    fn layout(&self, rect: egui::Rect) -> Vec<RowLayout> {
        let newest: Vec<usize> = (0..self.traces.len()).rev().take(MAX_ROWS).collect();
        let row_height = (rect.height() / newest.len().max(1) as f32).clamp(ROW_MIN, ROW_MAX);
        let column = |share: f32| rect.left() + rect.width() * share;

        newest
            .into_iter()
            .enumerate()
            .map(|(row, trace)| {
                let centre = rect.top() + row_height * (row as f32 + 0.5);
                let total = self.traces[trace].attempts.len();
                let shown = total.min(MAX_ATTEMPTS_PER_ROW);
                let first = total - shown;
                let span = (row_height - 18.0).max(0.0);
                let attempts = (0..shown)
                    .map(|slot| {
                        let y = if shown <= 1 {
                            centre
                        } else {
                            centre - span / 2.0 + span * slot as f32 / (shown - 1) as f32
                        };
                        (first + slot, egui::pos2(column(0.5), y))
                    })
                    .collect();
                RowLayout {
                    trace,
                    root: egui::pos2(column(0.06), centre),
                    router: egui::pos2(column(0.24), centre),
                    answer: egui::pos2(column(0.92), centre),
                    attempts,
                    folded: first,
                    fold_mark: egui::pos2(column(0.5) + 10.0, centre - row_height / 2.0 + 2.0),
                }
            })
            .collect()
    }

    fn describe(&self, hit: Hit) -> Option<String> {
        let trace = self.traces.get(hit.trace)?;
        Some(match hit.part {
            Part::Root => format!(
                "запрос от {} · {}",
                client_label(&trace.client),
                short_id(&trace.id)
            ),
            Part::Router => format!(
                "{} · правило {} · уверенность {:.2} · решение за {} мс",
                tier_label(&trace.tier),
                if trace.reason.is_empty() {
                    "не названо"
                } else {
                    &trace.reason
                },
                trace.confidence,
                trace.route_ms
            ),
            Part::Attempt(index) => {
                let attempt = trace.attempts.get(index)?;
                let rating = crate::gui::opencode_setup::model_rating(&attempt.model)
                    .map(|dpr| format!("рейтинг {dpr}"))
                    .unwrap_or_else(|| "рейтинг неизвестен".to_string());
                let outcome = if attempt.failed {
                    format!(
                        "сбой: {}",
                        if attempt.error_class.is_empty() {
                            "неизвестно"
                        } else {
                            &attempt.error_class
                        }
                    )
                } else {
                    "ответ получен".to_string()
                };
                format!(
                    "{} · {} · {} · {:.1} с · {} · {}",
                    attempt.stage,
                    attempt.model,
                    attempt.provider,
                    attempt.elapsed_ms as f32 / 1000.0,
                    rating,
                    outcome
                )
            }
            Part::Answer => match trace.phase {
                Phase::Running => "ответа ещё нет".to_string(),
                Phase::Done => "ответ получен".to_string(),
                Phase::Failed => "запрос не дал ответа".to_string(),
            },
        })
    }

    pub fn ui(&mut self, ui: &mut egui::Ui, theme: &ThemeConfig) {
        let now = ui.input(|input| input.time);
        self.poll_logs(now);
        let cadence = if self.animating(now) {
            ACTIVE_REPAINT
        } else {
            IDLE_REPAINT
        };
        ui.ctx().request_repaint_after(cadence);

        let available = ui.available_size();
        // Never clamp to a minimum ABOVE what is available: that is what pushed
        // the footer off the panel in the first prototype.
        let map_height = (available.y - FOOTER_HEIGHT).max(120.0);
        let (response, painter) =
            ui.allocate_painter(egui::vec2(available.x, map_height), egui::Sense::click());

        let rows = self.layout(response.rect);
        let hovered = response.hover_pos().and_then(|pos| hit_at(&rows, pos));
        if response.clicked() {
            self.pinned = match (hovered, self.pinned) {
                (Some(hit), Some(current)) if current == hit => None,
                (Some(hit), _) => Some(hit),
                (None, _) => None,
            };
        }
        let focus = self
            .pinned
            .filter(|hit| self.traces.get(hit.trace).is_some())
            .or(hovered);

        for row in &rows {
            self.paint_row(&painter, theme, now, row, focus);
        }
        self.paint_footer(ui, theme, focus);
    }

    fn paint_row(
        &self,
        painter: &egui::Painter,
        theme: &ThemeConfig,
        now: f64,
        row: &RowLayout,
        focus: Option<Hit>,
    ) {
        let trace = &self.traces[row.trace];
        let fade = fade_factor(trace, now);
        let lit = focus.is_none_or(|hit| hit.trace == row.trace);
        let level = fade * if lit { 1.0 } else { 0.3 };
        let accent = theme.accent_color();
        let success = theme.success_color();
        let error = theme.error_color();
        let weak = theme.weak_text_color();

        // Root → router: the request itself, growing from the moment it started.
        stroke_curve(
            painter,
            row.root,
            row.router,
            grow(now, trace.started),
            with_alpha(accent, alpha(150.0, level)),
            1.6,
        );
        painter.circle_filled(row.root, 7.0, with_alpha(accent, alpha(200.0, level)));
        painter.text(
            row.root + egui::vec2(0.0, 12.0),
            egui::Align2::CENTER_TOP,
            client_label(&trace.client),
            egui::FontId::proportional(11.0),
            with_alpha(weak, alpha(255.0, level)),
        );

        // Router node: the rule that fired and the mode it chose.
        painter.circle_filled(row.router, 8.0, with_alpha(accent, alpha(170.0, level)));
        let router_text = format!(
            "{} · {}",
            tier_label(&trace.tier),
            if trace.mode.is_empty() {
                "—"
            } else {
                &trace.mode
            }
        );
        painter.text(
            row.router + egui::vec2(0.0, 12.0),
            egui::Align2::CENTER_TOP,
            router_text,
            egui::FontId::proportional(11.0),
            with_alpha(weak, alpha(255.0, level)),
        );

        // Model branches. A failed call ends in a red stub; a successful one
        // converges into the answer after its branch has grown.
        for &(index, point) in &row.attempts {
            let attempt = &trace.attempts[index];
            let on_path = lit
                && match focus {
                    Some(Hit {
                        part: Part::Attempt(chosen),
                        ..
                    }) => chosen == index,
                    _ => true,
                };
            let branch_level = fade * if on_path { 1.0 } else { 0.3 };
            let colour = if attempt.failed { error } else { accent };
            let reveal = grow(now, attempt.born);

            stroke_curve(
                painter,
                row.router,
                point,
                reveal,
                with_alpha(colour, alpha(190.0, branch_level)),
                1.4,
            );
            if !attempt.failed {
                stroke_curve(
                    painter,
                    point,
                    row.answer,
                    grow(now, attempt.born + GROW_SECS),
                    with_alpha(success, alpha(170.0, branch_level)),
                    1.4,
                );
                let travel = (now - attempt.born - GROW_SECS) / PULSE_SECS;
                if (0.0..=1.0).contains(&travel) {
                    let head = curve_point(point, row.answer, travel as f32);
                    painter.circle_filled(
                        head,
                        3.2,
                        with_alpha(success, alpha(235.0, branch_level)),
                    );
                }
            }

            painter.circle_filled(point, 6.0, with_alpha(colour, alpha(150.0, branch_level)));
            painter.circle_stroke(
                point,
                6.0,
                egui::Stroke::new(1.0, with_alpha(colour, alpha(235.0, branch_level))),
            );
            let label = if attempt.failed {
                format!("{} · {} · сбой", short_label(&attempt.model), attempt.stage)
            } else {
                format!(
                    "{} · {} · {:.1} с",
                    short_label(&attempt.model),
                    attempt.stage,
                    attempt.elapsed_ms as f32 / 1000.0
                )
            };
            painter.text(
                point + egui::vec2(10.0, 0.0),
                egui::Align2::LEFT_CENTER,
                label,
                egui::FontId::proportional(11.0),
                with_alpha(weak, alpha(255.0, branch_level)),
            );
        }
        if row.folded > 0 {
            painter.text(
                row.fold_mark,
                egui::Align2::LEFT_TOP,
                format!("+{} ещё", row.folded),
                egui::FontId::proportional(10.0),
                with_alpha(weak, alpha(255.0, level)),
            );
        }

        // Answer node: dim while the request is open, green or red once settled.
        let (answer_colour, answer_text) = match trace.phase {
            Phase::Running => (weak, "…"),
            Phase::Done => (success, "ответ"),
            Phase::Failed => (error, "сбой"),
        };
        painter.circle_filled(
            row.answer,
            8.0,
            with_alpha(answer_colour, alpha(170.0, level)),
        );
        painter.text(
            row.answer + egui::vec2(0.0, 12.0),
            egui::Align2::CENTER_TOP,
            answer_text,
            egui::FontId::proportional(11.0),
            with_alpha(weak, alpha(255.0, level)),
        );
    }

    /// Fixed strip, so this text can never be pushed off the panel.
    fn paint_footer(&self, ui: &mut egui::Ui, theme: &ThemeConfig, focus: Option<Hit>) {
        ui.add_space(4.0);
        if self.traces.is_empty() {
            ui.colored_label(
                theme.weak_text_color(),
                "Пока пусто: строка появится, как только агент обратится к Delegator.",
            );
            return;
        }
        match focus.and_then(|hit| self.describe(hit)) {
            Some(text) => {
                ui.label(egui::RichText::new(text).color(theme.accent_color()));
                ui.colored_label(theme.weak_text_color(), "клик закрепляет выделение");
            }
            None => {
                ui.colored_label(
                    theme.weak_text_color(),
                    "Наведите на узел — подсветится его строка; клик закрепляет.",
                );
                let calls: usize = self.traces.iter().map(|trace| trace.attempts.len()).sum();
                ui.colored_label(
                    theme.weak_text_color(),
                    format!(
                        "строк {} · вызовов {} · событий за сеанс {} · зелёная ветка — ответ, красная — сбой · только процессы, без текста задач и ответов",
                        self.traces.len(),
                        calls,
                        self.events_seen
                    ),
                );
            }
        }
    }
}

fn hit_at(rows: &[RowLayout], pos: egui::Pos2) -> Option<Hit> {
    for row in rows {
        let mut parts = vec![
            (Part::Root, row.root),
            (Part::Router, row.router),
            (Part::Answer, row.answer),
        ];
        parts.extend(
            row.attempts
                .iter()
                .map(|(index, point)| (Part::Attempt(*index), *point)),
        );
        if let Some((part, _)) = parts
            .into_iter()
            .find(|(_, point)| point.distance(pos) <= 9.0)
        {
            return Some(Hit {
                trace: row.trace,
                part,
            });
        }
    }
    None
}

/// Control points with horizontal tangents at both ends: the classic tree bend.
fn control_points(from: egui::Pos2, to: egui::Pos2) -> [egui::Pos2; 4] {
    let bend = (to.x - from.x) * 0.5;
    [
        from,
        egui::pos2(from.x + bend, from.y),
        egui::pos2(to.x - bend, to.y),
        to,
    ]
}

/// Point on the branch at `t` in 0..=1, as a cubic Bézier.
fn curve_point(from: egui::Pos2, to: egui::Pos2, t: f32) -> egui::Pos2 {
    let [p0, p1, p2, p3] = control_points(from, to);
    let u = 1.0 - t;
    let mix = |a: f32, b: f32, c: f32, d: f32| {
        u * u * u * a + 3.0 * u * u * t * b + 3.0 * u * t * t * c + t * t * t * d
    };
    egui::pos2(mix(p0.x, p1.x, p2.x, p3.x), mix(p0.y, p1.y, p2.y, p3.y))
}

/// Draws the first `progress` (0..1) of a branch. Growth is drawn from the same
/// curve the pulse rides on, so a pulse never leaves the visible line.
fn stroke_curve(
    painter: &egui::Painter,
    from: egui::Pos2,
    to: egui::Pos2,
    progress: f32,
    colour: egui::Color32,
    width: f32,
) {
    if progress <= 0.0 {
        return;
    }
    const STEPS: usize = 24;
    let steps = ((STEPS as f32) * progress).ceil().max(1.0) as usize;
    let points: Vec<egui::Pos2> = (0..=steps)
        .map(|step| curve_point(from, to, progress * step as f32 / steps as f32))
        .collect();
    painter.add(egui::Shape::line(points, egui::Stroke::new(width, colour)));
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

    fn router_line(request_id: &str, tier: &str, mode: &str) -> String {
        format!(
            r#"{{"requestId":"{request_id}","client":"ide","mode":"{mode}","tier":"{tier}","reason":"code-task","confidence":0.8,"routeMs":2314}}"#
        )
    }

    fn usage_line(request_id: &str, model: &str, ok: bool, elapsed_ms: u64) -> String {
        let error_class = if ok { "" } else { "timeout" };
        format!(
            r#"{{"requestId":"{request_id}","client":"ide","stage":"improve","mode":"ask","provider":"orcarouter","model":"{model}","totalTokens":9514,"elapsedMs":{elapsed_ms},"ok":{ok},"errorClass":"{error_class}"}}"#
        )
    }

    #[test]
    fn a_usage_record_joins_its_request_by_request_id() {
        let mut view = ThinkingView::default();
        view.ingest_router(&router_line("r-1", "model", "delegate"), true, 10.0);
        view.ingest_usage(&usage_line("r-1", "a/x", true, 500), true, 10.5);
        view.ingest_usage(&usage_line("r-1", "b/y", false, 900), true, 11.0);
        view.ingest_usage(&usage_line("r-2", "a/x", true, 300), true, 11.5);

        assert_eq!(view.traces.len(), 2);
        let first = view.traces.iter().find(|t| t.id == "r-1").expect("r-1");
        assert_eq!(first.attempts.len(), 2);
        assert_eq!(
            first.mode, "delegate",
            "the router's mode wins over usage's"
        );
        assert_eq!(first.tier, "model");
        let second = view.traces.iter().find(|t| t.id == "r-2").expect("r-2");
        assert_eq!(second.attempts.len(), 1);
    }

    #[test]
    fn a_failed_call_does_not_finish_and_a_quiet_failure_is_given_up() {
        let mut view = ThinkingView::default();
        view.ingest_router(&router_line("r-1", "rules", "delegate"), true, 0.0);
        view.ingest_usage(&usage_line("r-1", "m", false, 100), true, 1.0);

        view.settle(10.0);
        assert_eq!(view.traces[0].phase, Phase::Running);
        view.settle(21.5);
        assert_eq!(view.traces[0].phase, Phase::Failed);
    }

    #[test]
    fn a_successful_call_finishes_once_the_request_goes_quiet() {
        let mut view = ThinkingView::default();
        view.ingest_router(&router_line("r-1", "rules", "delegate"), true, 0.0);
        view.ingest_usage(&usage_line("r-1", "m", true, 800), true, 1.0);

        view.settle(3.5);
        assert_eq!(view.traces[0].phase, Phase::Running);
        view.settle(4.1);
        assert_eq!(view.traces[0].phase, Phase::Done);
    }

    #[test]
    fn a_record_after_a_finish_reopens_the_request() {
        let mut view = ThinkingView::default();
        view.ingest_router(&router_line("r-1", "rules", "delegate"), true, 0.0);
        view.ingest_usage(&usage_line("r-1", "m", true, 800), true, 1.0);
        view.settle(5.0);
        assert_eq!(view.traces[0].phase, Phase::Done);

        view.ingest_usage(&usage_line("r-1", "n", true, 300), true, 6.0);
        assert_eq!(view.traces[0].phase, Phase::Running);
        assert!(view.traces[0].finished_at.is_none());
    }

    /// History must not replay as if it were happening: it is settled, still, and
    /// leaves the map after the fade.
    #[test]
    fn history_is_not_animated_and_fades_out() {
        let mut view = ThinkingView::default();
        let now = 1000.0;
        view.ingest_router(&router_line("r-1", "rules", "delegate"), false, now);
        view.ingest_usage(&usage_line("r-1", "m", true, 800), false, now);
        view.settle(now);

        assert_eq!(view.traces[0].phase, Phase::Done);
        assert!(!view.animating(now));
        view.prune(now + FADE_SECS - 1.0);
        assert_eq!(view.traces.len(), 1);
        view.prune(now + FADE_SECS + 1.0);
        assert!(view.traces.is_empty());
    }

    #[test]
    fn a_crowded_row_shows_the_newest_calls_and_folds_the_older() {
        let mut view = ThinkingView::default();
        view.ingest_router(&router_line("r-1", "rules", "delegate"), true, 0.0);
        for index in 0..6 {
            view.ingest_usage(
                &usage_line("r-1", &format!("m{index}"), true, 100),
                true,
                index as f64,
            );
        }
        let rect = egui::Rect::from_min_size(egui::pos2(0.0, 0.0), egui::vec2(800.0, 200.0));
        let rows = view.layout(rect);

        let shown: Vec<usize> = rows[0].attempts.iter().map(|(index, _)| *index).collect();
        assert_eq!(shown, vec![2, 3, 4, 5]);
        assert_eq!(rows[0].folded, 2);
    }

    #[test]
    fn rows_are_newest_first_and_capped() {
        let mut view = ThinkingView::default();
        for index in 0..8 {
            view.ingest_router(
                &router_line(&format!("r-{index}"), "rules", "ask"),
                true,
                0.0,
            );
        }
        let rect = egui::Rect::from_min_size(egui::pos2(0.0, 0.0), egui::vec2(800.0, 600.0));
        let rows = view.layout(rect);

        assert_eq!(rows.len(), MAX_ROWS);
        assert_eq!(view.traces[rows[0].trace].id, "r-7");
    }

    #[test]
    fn the_map_is_still_when_nothing_is_live() {
        let mut view = ThinkingView::default();
        view.ingest_router(&router_line("r-1", "rules", "delegate"), true, 0.0);
        view.ingest_usage(&usage_line("r-1", "m", true, 800), true, 0.0);
        assert!(view.animating(0.5), "a reveal is in progress");

        view.settle(4.0);
        assert!(!view.animating(10.0));
    }

    #[test]
    fn long_model_ids_are_shortened_to_the_distinctive_tail() {
        assert_eq!(
            short_label("orcarouter/anthropic/claude-sonnet-5"),
            "claude-sonnet-5"
        );
        let long = short_label("provider/a-very-long-model-identifier-that-keeps-going-on");
        assert!(long.chars().count() <= 24, "{long}");
        assert!(long.ends_with('…'), "{long}");
    }

    #[test]
    fn a_branch_starts_at_its_parent_and_ends_on_its_target() {
        let from = egui::pos2(0.0, 0.0);
        let to = egui::pos2(100.0, 50.0);
        assert_eq!(curve_point(from, to, 0.0), from);
        assert_eq!(curve_point(from, to, 1.0), to);
        let mid = curve_point(from, to, 0.5);
        assert!(mid.x > 0.0 && mid.x < 100.0 && mid.y > 0.0 && mid.y < 50.0);
    }

    /// The whole privacy claim of this tab in one test: feed it records that DO
    /// carry task and answer text and prove none of it can be reached.
    #[test]
    fn chat_content_is_structurally_unreachable() {
        let router = r#"{"requestId":"r-1","client":"ide","mode":"delegate","tier":"rules",
            "reason":"code-task","confidence":0.5,
            "promptSummary":"СЕКРЕТ: перепиши мой приватный ключ"}"#;
        let usage = r#"{"requestId":"r-1","client":"ide","stage":"improve","mode":"ask",
            "provider":"orcarouter","model":"orcarouter/x/y","elapsedMs":10,"ok":false,
            "errorClass":"timeout","outputPreview":"вот ваш приватный ключ",
            "errorPreview":"secret error text","promptSummary":"СЕКРЕТ"}"#;
        let mut view = ThinkingView::default();
        view.ingest_router(router, true, 1.0);
        view.ingest_usage(usage, true, 1.0);

        let haystack = format!("{:?}", view.traces);
        assert!(!haystack.contains("СЕКРЕТ"), "{haystack}");
        assert!(!haystack.contains("приватный"), "{haystack}");
        assert!(!haystack.contains("secret"), "{haystack}");
    }
}
