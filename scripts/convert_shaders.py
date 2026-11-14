#!/usr/bin/env python3
"""Пробная конвертация GL-шейдеров OpenXRay в Metal Shading Language.

Повторяет то, что делает движок (src/Layers/xrRenderPC_GL/rgl_shaders.cpp):
текстово подставляет #include, добавляет в начало #version и набор define, затем
  GLSL 410 --glslang--> SPIR-V --SPIRV-Cross--> MSL 2.1 (iOS)

Использование:
  convert_shaders.py <каталог shaders/gl> <выходной каталог> <glslangValidator> <spirv-cross>
"""
import json
import os
import re
import subprocess
import sys
from collections import Counter

INCLUDE_RE = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)

# Наборы define, как их выставил бы движок (подмножество опций из rgl_shaders.cpp).
COMMON = {}  # ISAMPLE по умолчанию задаёт common_policies.h
PRESETS = {
    "low": {"SMAP_size": "1024", "SKIN_NONE": "1", "USE_HWSMAP": "1", "USE_R2_STATIC_SUN": "1",
            "USE_SHOC_RESOURCES": "1", "SUN_QUALITY": "1"},
    "high": {"SMAP_size": "2048", "SKIN_NONE": "1", "USE_HWSMAP": "1", "USE_BRANCHING": "1",
             "USE_VTF": "1", "USE_SJITTER": "1", "USE_SHOC_RESOURCES": "1",
             "SSAO_QUALITY": "2", "SUN_QUALITY": "2", "SUN_SHAFTS_QUALITY": "2",
             "USE_SOFT_PARTICLES": "1", "USE_SOFT_WATER": "1", "FP16_FILTER": "1", "FP16_BLEND": "1"},
}
# Если шейдер не собрался с пресетом, пробуем реалистичные дополнения:
# модели рисуются с SKIN_0..4, SSAO-шейдеры — с включённым SSAO и т. д.
FALLBACKS = [
    {"SKIN_0": "1", "SKIN_NONE": None},
    {"SKIN_1": "1", "SKIN_NONE": None},
    {"USE_HWSMAP": "1"},
    {"USE_SSAO_BLUR": "1", "SSAO_OPT_DATA": "2", "USE_HBAO": "1"},
    {"HDAO": "1", "SSAO_OPT_DATA": "2"},
    {"GBUFFER_OPTIMIZATION": "1"},
    {"GBUFFER_OPTIMIZATION": "1", "USE_MSAA": "1", "MSAA_SAMPLES": "4", "ISAMPLE": "uint(0)"},
]

# -V -R: Vulkan-SPIR-V с «расслабленными» правилами — все свободные uniform собираются
# в один блок gl_DefaultUniformBlock. Без этого SPIRV-Cross делает из каждого uniform
# отдельный constant-буфер, и драйвер Metal отвергает передачу таких буферов во
# вспомогательные функции (address space mismatch), а массивы uniform съедают >31 слота.
GLSLANG_MODE = ["-V", "-R"]

CASE_MISSES = Counter()


def resolve(root, rel):
    """Ищет файл без учёта регистра — как файловая система Windows."""
    cur = root
    for part in rel.replace("\\", "/").split("/"):
        exact = os.path.join(cur, part)
        if os.path.exists(exact):
            cur = exact
            continue
        match = [e for e in os.listdir(cur) if e.lower() == part.lower()]
        if not match:
            raise FileNotFoundError(rel)
        CASE_MISSES[rel] += 1
        cur = os.path.join(cur, match[0])
    return cur


def inline_includes(root, rel, stack=()):
    if rel in stack:
        raise RuntimeError("циклический include: " + " -> ".join(stack + (rel,)))
    with open(resolve(root, rel), encoding="utf-8", errors="replace") as f:
        text = f.read()
    return INCLUDE_RE.sub(lambda m: inline_includes(root, m.group(1), stack + (rel,)) + "\n", text)


def make_header(defines):
    h = "#version 410\n#extension GL_ARB_separate_shader_objects : enable\n"
    return h + "".join(f"#define {k} {v}\n" for k, v in defines.items() if v is not None)


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def first_error(log):
    for line in log.splitlines():
        if "error" in line.lower():
            return re.sub(r"\S+\.(vert|frag):\d+:", "", line).strip()[:160]
    return (log.splitlines() or ["?"])[0][:160]


def convert_one(src, pdir, name, header, glslang, spvc):
    """None — успех, иначе (вид ошибки, текст ошибки)."""
    stage = "vert" if name.endswith(".vs") else "frag"
    try:
        body = inline_includes(src, name)
    except Exception as e:  # noqa: BLE001
        return "glsl_fail", "include: " + str(e)[:80]
    base = os.path.join(pdir, name.replace(".", "_"))
    glsl, spv, msl = base + "." + stage, base + ".spv", base + ".metal"
    with open(glsl, "w") as f:
        f.write(header + body)
    code, log = run([glslang, *GLSLANG_MODE, "--aml", "--amb", "-S", stage, "-o", spv, glsl])
    if code != 0:
        return "glsl_fail", "glslang: " + first_error(log)
    code, log = run([spvc, spv, "--msl", "--msl-ios", "--msl-version", "20100",
                     "--msl-decoration-binding", "--output", msl])
    if code != 0:
        return "msl_fail", "spirv-cross: " + first_error(log)
    # Отражение (reflection) для Metal-рендера: где лежат uniform-константы,
    # текстуры и сэмплеры, какие у них индексы [[buffer]]/[[texture]]/[[sampler]].
    code, log = run([spvc, spv, "--reflect", "--output", base + ".json"])
    if code != 0:
        return "msl_fail", "spirv-cross --reflect: " + first_error(log)
    return None


def main():
    src, out, glslang, spvc = sys.argv[1:5]
    files = sorted(f for f in os.listdir(src) if f.endswith((".vs", ".ps")))
    report = {}
    for preset, defines in PRESETS.items():
        pdir = os.path.join(out, preset)
        os.makedirs(pdir, exist_ok=True)
        res = {"total": len(files), "ok": [], "ok_with_fallback": {}, "glsl_fail": [], "msl_fail": [],
               "errors": Counter()}
        for name in files:
            first = None
            for extra in [{}] + FALLBACKS:
                d = dict(COMMON, **defines)
                d.update(extra)
                status = convert_one(src, pdir, name, make_header(d), glslang, spvc)
                if status is None:
                    res["ok"].append(name)
                    if extra:
                        res["ok_with_fallback"][name] = {k: v for k, v in extra.items() if v}
                    break
                first = first or status
            else:
                kind, err = first
                res[kind].append(name)
                res["errors"][err] += 1
        res["errors"] = res["errors"].most_common()
        report[preset] = res
        print(f"[{preset}] всего {len(files)}: MSL готов {len(res['ok'])} "
              f"(из них с доп. define {len(res['ok_with_fallback'])}), "
              f"ошибка GLSL→SPIR-V {len(res['glsl_fail'])}, ошибка SPIR-V→MSL {len(res['msl_fail'])}")
        for err, n in res["errors"][:12]:
            print(f"   {n:4d} × {err}")
        if res["glsl_fail"] or res["msl_fail"]:
            print("   не собрались:", ", ".join(res["glsl_fail"] + res["msl_fail"]))
    print(f"include с другим регистром букв: {len(CASE_MISSES)} разных путей")
    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
