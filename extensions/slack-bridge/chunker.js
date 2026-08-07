"use strict";
// extensions/slack-bridge/chunker.ts
// Split text into Slack-friendly chunks (<= MAX chars each, prefix included)
// without breaking code fences. Multi-chunk output is prefixed "(part N/M)".
Object.defineProperty(exports, "__esModule", { value: true });
exports.MAX_CHUNK = void 0;
exports.chunk = chunk;
exports.MAX_CHUNK = 3000;
var FENCE_RE = /^[ \t]*```/; // a code-fence LINE (not inline ``` in prose)
var FENCE_TOKEN = "```";
/** Count code-fence lines in a slice (used to detect an unclosed block). */
function fenceLineCount(s) {
    var n = 0;
    for (var _i = 0, _a = s.split("\n"); _i < _a.length; _i++) {
        var line = _a[_i];
        if (FENCE_RE.test(line))
            n++;
    }
    return n;
}
/** Offset (absolute) of the last line in [i,end) that is a fence line, or i if none. */
function findLastFenceLineStart(text, i, end) {
    var last = i;
    var pos = i;
    for (var _i = 0, _a = text.slice(i, end).split("\n"); _i < _a.length; _i++) {
        var line = _a[_i];
        if (FENCE_RE.test(line))
            last = pos;
        pos += line.length + 1; // +1 for the "\n"
    }
    return last;
}
// ponytail ceilings: (1) surrogate-pair edge — `slice` is UTF-16 code-unit
// based; a 4-byte emoji split at the boundary yields a lone surrogate; Slack
// renders as replacement char (cosmetic). Codepoint-safe split (`Array.from`)
// is the upgrade. (2) code block containing inline ``` in prose is
// unsplittable at the 3000 boundary — extend-path matches the next fence LINE
// (regex), so an inline ``` inside a block won't prematurely close it; if a
// block has no closing fence line, the chunk grows to end-of-text.
function chunk(text) {
    var _a;
    if (!text)
        return [];
    if (text.length <= exports.MAX_CHUNK)
        return [text];
    var parts = [];
    // Reserve room for the "(part N/M)\n" prefix; worst case "(part 99/99)\n" = 13 chars.
    var reserve = 14;
    var sliceLen = exports.MAX_CHUNK - reserve;
    var i = 0;
    while (i < text.length) {
        var end = Math.min(i + sliceLen, text.length);
        if (end < text.length) {
            // Don't split inside an open code fence: if this slice has an odd number
            // of fence lines, pull the boundary back to the start of the last fence line.
            if (fenceLineCount(text.slice(i, end)) % 2 === 1) {
                var lastFenceLineStart = findLastFenceLineStart(text, i, end);
                if (lastFenceLineStart > i)
                    end = lastFenceLineStart;
                // If the only fence line starts at offset 0 (fence opens exactly at the
                // slice start), we can't pull back — extend to the block's closing fence line.
                if (lastFenceLineStart === i) {
                    var m = text.slice(end).match(new RegExp(FENCE_RE.source, "m"));
                    if (m)
                        end = end + ((_a = m.index) !== null && _a !== void 0 ? _a : 0) + m[0].length;
                }
            }
            if (end <= i)
                end = i + sliceLen; // never stall — prefer progress over perfection
        }
        parts.push(text.slice(i, end));
        i = end;
    }
    if (parts.length === 1)
        return parts;
    return parts.map(function (p, idx) { return "(part ".concat(idx + 1, "/").concat(parts.length, ")\n").concat(p); });
}
