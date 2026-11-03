"""Static rules for solution code (shared by the hidden scorers and the agent-visible check.py scripts).

check_code(path, task) -> None if the file is fine, else a one-line description of the first violation.
A violation scores 0 for the whole task. Keep the copy in template/ identical to this file.

Delegator build: this is the ONE static check. v1.7 rules plus what the Delegator guard used to add (it is gone):
a UTF-8 BOM is accepted (Windows editors write one), routing/sat solutions get a size cap, may not mention grader
data (paths, scorer names), and may not use memoryview or the tracing/stdio/meta_path hooks. Where the two rule
sets differed the stricter one is kept, so a file is accepted or rejected identically by the grader, `check.py`
and the pre-scan in `grade_run.py`.
"""
import ast
import os

COMMON_IMPORTS = {'math', 'collections', 'heapq', 'struct', 'array', 'itertools', 'functools', 'bisect', 'typing',
                  'dataclasses', 'operator'}
ALLOWED_IMPORTS = {
    'compress': COMMON_IMPORTS,
    'routing': COMMON_IMPORTS | {'random', 'time', 'sys'},
    'sat': COMMON_IMPORTS | {'random', 'time', 'sys'},
}
SYS_ALLOWED = {'setrecursionlimit', 'maxsize'}      # the only parts of `sys` a solution may use
MAX_SIZE = {'compress': 60 * 1024, 'routing': 400 * 1024, 'sat': 400 * 1024}   # bytes of the main file
# routing/sat only: a solution must not look at the grader (compress codecs may say "corpus" in a comment)
GRADER_TASKS = ('routing', 'sat')
FORBIDDEN_TEXT = ('hidden/', 'hidden\\', 'reference_cost', 'instances.json', 'index.json', 'corpus', 'score_routing',
                  'score_sat', 'score_compress', 'BENCH_TARGET', 'grade_run', 'run_info', 'coding-bench')
EXTRA_NAMES = {'memoryview'}
EXTRA_ATTRS = {'stdin', 'stdout', '_exit', '_current_frames', 'settrace', 'setprofile', 'meta_path'}

FORBIDDEN_NAMES = {'open', 'eval', 'exec', 'compile', '__import__', 'getattr', 'setattr', 'delattr', 'globals',
                   'locals', 'vars', 'breakpoint', 'input', 'help', 'attrgetter', 'methodcaller'}
DUNDERS = {'__builtins__', '__globals__', '__subclasses__', '__class__', '__bases__', '__base__', '__mro__',
           '__loader__', '__spec__', '__dict__', '__code__', '__closure__', '__getattribute__', '__self__',
           '__traceback__', '__func__', '__wrapped__', '__reduce__', '__reduce_ex__', '__getattr__', '__setattr__'}
FORBIDDEN_ATTRS = DUNDERS | {
    'attrgetter', 'methodcaller', 'sys', 'os', 'modules', 'builtins', '_os', '_sys', 'inspect', 'currentframe',
    '_getframe', 'stack', 'gi_frame', 'gi_code', 'cr_frame', 'cr_code', 'ag_frame', 'ag_code', 'f_globals',
    'f_builtins', 'f_locals', 'f_back', 'f_code', 'tb_frame', 'tb_next', 'co_consts'}


def check_code(path, task):
    if not os.path.exists(path):
        return "%s not found" % os.path.basename(path)
    limit = MAX_SIZE.get(task)
    if limit and os.path.getsize(path) > limit:
        return "file is larger than %d KB (embedded precomputed data?)" % (limit // 1024)
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:   # -sig: a BOM must not turn into a parse error
            code = fh.read()
        tree = ast.parse(code)
    except (SyntaxError, ValueError, UnicodeDecodeError) as exc:
        return "cannot parse: %s" % exc
    allowed = ALLOWED_IMPORTS[task]
    extra = task in GRADER_TASKS
    names = FORBIDDEN_NAMES | (EXTRA_NAMES if extra else set())
    attrs = FORBIDDEN_ATTRS | (EXTRA_ATTRS if extra else set())
    if extra:
        low = code.lower()
        for text in FORBIDDEN_TEXT:
            if text.lower() in low:
                return "mentions grader data: %s" % text
    sys_names, sys_ok = set(), set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.name.split('.')[0] not in allowed:
                    return "forbidden import: %s" % a.name
                if a.name == 'sys':
                    sys_names.add(a.asname or 'sys')
                elif '.' in a.name and a.name.split('.')[0] == 'sys':
                    return "forbidden import: %s" % a.name
        elif isinstance(node, ast.ImportFrom):
            if node.level or not node.module or node.module.split('.')[0] not in allowed:
                return "forbidden import: %s" % (node.module or "relative import")
            for a in node.names:
                if a.name in names or a.name in attrs:
                    return "forbidden name in import: %s" % a.name
                if node.module == 'sys' and a.name not in SYS_ALLOWED:
                    return "forbidden: from sys import %s" % a.name
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute):
            if node.attr in attrs:
                return "forbidden attribute: .%s" % node.attr
            if isinstance(node.value, ast.Name) and node.value.id in sys_names:
                if node.attr not in SYS_ALLOWED:
                    return "forbidden: sys.%s (only %s are allowed)" % (node.attr, ", ".join(sorted(SYS_ALLOWED)))
                sys_ok.add(id(node.value))
        elif isinstance(node, ast.Name):
            if node.id in names or node.id in DUNDERS:
                return "forbidden name: %s (also as a variable name)" % node.id
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            if any(d in node.value for d in DUNDERS):
                return "forbidden string constant: %r" % node.value[:40]
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and node.id in sys_names and id(node) not in sys_ok:
            return "forbidden: `%s` may only be used as %s.<name>" % (node.id, node.id)
    return None
