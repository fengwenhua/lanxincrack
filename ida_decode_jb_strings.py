#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Decode obfuscated jailbreak-detection strings in LxBase from IDA.

Usage in IDA Python:
  exec(open("/path/to/ida_decode_jb_strings.py", "r", encoding="utf-8").read())
"""

import json
import re
import struct

import idc
import ida_bytes
import ida_hexrays


# Functions from this analysis that contain obfuscated jailbreak string material.
TARGET_FUNCS = {
    "CoreMessUtils_isJailBreak1": 0x1C9690,
    "CoreMessUtils_isJailBreak2": 0x1CA91C,
    "CoreMessUtils_isJailBreak3": 0x1CACD0,
    "CoreMessUtils_isJailBreak4": 0x1CCE7C,
    "CoreMessUtils_isJailBreak5": 0x1CD964,
    "CoreMessUtils_isJailBreak6": 0x1CE41C,
    "CoreMessUtils_isJailBreak7": 0x1CE954,
    "CoreMessUtils_isJailBreak8": 0x1CF0F8,
}

# Key symbols found during reverse analysis.
SINGLE_STRING_SYMBOLS = [
    "asc_38E40F",   # cydia://
    "byte_38E670",  # /usr/lib/system/libsystem_kernel.dylib
    "byte_38E6D0",  # Library/MobileSubstrate/MobileSubstrate.dylib
    "byte_38E720",  # DYLD_INSERT_LIBRARIES
    "asc_38E760",   # /User/Applications/
    "asc_38E7D0",   # /private/var/containers/Bundle/Application/
    "aJ_6",         # .dylib
]

PTR_ARRAYS = {
    "_jailbreak_tool_pathes": 5,
    "_jailbreak_tool_apps": 3,
}


RE_XOR_INDEX = re.compile(
    r"\b(byte_[0-9A-Fa-f]+|asc_[0-9A-Fa-f]+|a[A-Za-z0-9_]+)\[(\d+)\]\s*=\s*byte_([0-9A-Fa-f]+)\s*\^\s*(0x[0-9A-Fa-f]+|\d+)"
)
RE_XOR_DIRECT = re.compile(
    r"\b(byte_[0-9A-Fa-f]+)\s*=\s*byte_([0-9A-Fa-f]+)\s*\^\s*(0x[0-9A-Fa-f]+|\d+)"
)
RE_NOT_INDEX = re.compile(
    r"\b(byte_[0-9A-Fa-f]+|asc_[0-9A-Fa-f]+|a[A-Za-z0-9_]+)\[(\d+)\]\s*=\s*~byte_([0-9A-Fa-f]+)"
)
RE_NOT_DIRECT = re.compile(r"\b(byte_[0-9A-Fa-f]+)\s*=\s*~byte_([0-9A-Fa-f]+)")
RE_COPY_INDEX = re.compile(
    r"\b(byte_[0-9A-Fa-f]+|asc_[0-9A-Fa-f]+|a[A-Za-z0-9_]+)\[(\d+)\]\s*=\s*byte_([0-9A-Fa-f]+)\b"
)
RE_COPY_DIRECT = re.compile(r"\b(byte_[0-9A-Fa-f]+)\s*=\s*byte_([0-9A-Fa-f]+)\b")


def _name_ea(name):
    ea = idc.get_name_ea_simple(name)
    if ea == idc.BADADDR:
        return None
    return ea


def _read_u8(ea):
    return ida_bytes.get_byte(ea) & 0xFF


def _read_cstr(ea, writes, max_len=512):
    out = []
    for i in range(max_len):
        cur = ea + i
        v = writes[cur] if cur in writes else _read_u8(cur)
        if v == 0:
            break
        out.append(v)
    raw = bytes(out)
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1", errors="replace")


def _read_qword(ea):
    data = ida_bytes.get_bytes(ea, 8)
    if not data or len(data) != 8:
        return None
    return struct.unpack("<Q", data)[0]


def _apply_line(line, writes):
    line = line.strip()
    if "byte_" not in line or "=" not in line:
        return

    m = RE_XOR_INDEX.search(line)
    if m:
        dst_sym, idx_s, src_hex, k_s = m.groups()
        dst_ea = _name_ea(dst_sym)
        if dst_ea is not None:
            idx = int(idx_s)
            src = int(src_hex, 16)
            k = int(k_s, 0)
            writes[dst_ea + idx] = _read_u8(src) ^ k
        return

    m = RE_XOR_DIRECT.search(line)
    if m:
        dst_sym, src_hex, k_s = m.groups()
        dst_ea = _name_ea(dst_sym)
        if dst_ea is not None:
            src = int(src_hex, 16)
            k = int(k_s, 0)
            writes[dst_ea] = _read_u8(src) ^ k
        return

    m = RE_NOT_INDEX.search(line)
    if m:
        dst_sym, idx_s, src_hex = m.groups()
        dst_ea = _name_ea(dst_sym)
        if dst_ea is not None:
            idx = int(idx_s)
            src = int(src_hex, 16)
            writes[dst_ea + idx] = (~_read_u8(src)) & 0xFF
        return

    m = RE_NOT_DIRECT.search(line)
    if m:
        dst_sym, src_hex = m.groups()
        dst_ea = _name_ea(dst_sym)
        if dst_ea is not None:
            src = int(src_hex, 16)
            writes[dst_ea] = (~_read_u8(src)) & 0xFF
        return

    m = RE_COPY_INDEX.search(line)
    if m:
        dst_sym, idx_s, src_hex = m.groups()
        dst_ea = _name_ea(dst_sym)
        if dst_ea is not None:
            idx = int(idx_s)
            src = int(src_hex, 16)
            writes[dst_ea + idx] = _read_u8(src)
        return

    m = RE_COPY_DIRECT.search(line)
    if m:
        dst_sym, src_hex = m.groups()
        dst_ea = _name_ea(dst_sym)
        if dst_ea is not None:
            src = int(src_hex, 16)
            writes[dst_ea] = _read_u8(src)
        return


def collect_obfuscated_writes():
    writes = {}

    if not ida_hexrays.init_hexrays_plugin():
        raise RuntimeError("Hex-Rays decompiler is not available in this IDA instance.")

    for name, fva in TARGET_FUNCS.items():
        try:
            cfunc = ida_hexrays.decompile(fva)
            text = str(cfunc)
        except Exception as exc:
            print("[!] decompile failed for %s (0x%X): %s" % (name, fva, exc))
            continue
        for line in text.splitlines():
            _apply_line(line, writes)
    return writes


def decode_report():
    writes = collect_obfuscated_writes()
    report = {
        "target_functions": {
            n: "0x%X" % ea for n, ea in TARGET_FUNCS.items()
        },
        "decoded_arrays": {},
        "decoded_symbols": {},
    }

    for arr_name, count in PTR_ARRAYS.items():
        arr_ea = _name_ea(arr_name)
        if arr_ea is None:
            report["decoded_arrays"][arr_name] = {"error": "symbol_not_found"}
            continue
        entries = []
        for i in range(count):
            p = _read_qword(arr_ea + i * 8)
            if p is None:
                entries.append({"index": i, "error": "ptr_read_failed"})
                continue
            entries.append(
                {
                    "index": i,
                    "ptr": "0x%X" % p,
                    "text": _read_cstr(p, writes),
                }
            )
        report["decoded_arrays"][arr_name] = entries

    for sym in SINGLE_STRING_SYMBOLS:
        ea = _name_ea(sym)
        if ea is None:
            report["decoded_symbols"][sym] = {"error": "symbol_not_found"}
            continue
        report["decoded_symbols"][sym] = {
            "ea": "0x%X" % ea,
            "text": _read_cstr(ea, writes),
        }

    return report


if __name__ == "__main__":
    result = decode_report()
    print(json.dumps(result, ensure_ascii=False, indent=2))

