package com.efinity.ti60

import org.json.JSONArray
import org.json.JSONObject

/** Pure scene statistics from sampled pixels; JVM-testable without Android graphics. */
object SceneStats {
    class Stats(val brightnessMean: Int, val brightnessStd: Int, val saturationMean: Int,
                val warmth: Double, val dominant: List<List<Int>>, val histogram: List<Double>)

    /** pixels: ARGB ints. Samples sparsely for speed; deterministic. */
    fun analyze(pixels: IntArray, width: Int, height: Int): Stats {
        require(width > 0 && height > 0 && pixels.size >= width * height) { "像素缓冲无效" }
        val strideX = maxOf(1, width / 80)
        val strideY = maxOf(1, height / 60)
        var n = 0L
        var sum = 0.0; var sum2 = 0.0; var satSum = 0.0; var rSum = 0.0; var bSum = 0.0
        val hist = DoubleArray(16); val buckets = HashMap<Long, Long>()
        var y = 0
        while (y < height) {
            var x = 0
            while (x < width) {
                val p = pixels[y * width + x]
                val r = (p shr 16) and 0xff; val g = (p shr 8) and 0xff; val b = p and 0xff
                val l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                sum += l; sum2 += l * l
                hist[mathMin(15, (l / 16).toInt())] += 1.0
                val mx = maxOf(r, g, b); val mn = minOf(r, g, b)
                satSum += if (mx == 0) 0.0 else (mx - mn).toDouble() / mx
                rSum += r; bSum += b
                val key = ((r shr 5) * 64 + (g shr 5) * 8 + (b shr 5)).toLong()
                buckets[key] = (buckets[key] ?: 0L) + 1
                n++; x += strideX
            }
            y += strideY
        }
        val mean = sum / n
        val std = kotlin.math.sqrt(maxOf(0.0, sum2 / n - mean * mean))
        val total = hist.sum()
        val dominant = buckets.entries.sortedByDescending { it.value }.take(4).map { (key, cnt) ->
            val r = ((key / 64).toInt()) * 32 + 16; val g = ((key / 8 % 8).toInt()) * 32 + 16; val b = ((key % 8).toInt()) * 32 + 16
            listOf(r, g, b, ((cnt.toDouble() / n) * 1000).toInt())
        }
        return Stats(mean.toInt(), std.toInt(), (satSum / n * 255).toInt(),
            (rSum - bSum) / (255.0 * n), dominant, hist.map { it / total })
    }

    fun json(s: Stats): JSONObject = JSONObject().put("brightness_mean",s.brightnessMean)
        .put("brightness_std",s.brightnessStd).put("saturation_mean",s.saturationMean).put("warmth",s.warmth)
        .put("dominant_colors",JSONArray().also { arr -> s.dominant.forEach { c ->
            arr.put(JSONObject().put("rgb",JSONArray(c.take(3))).put("ratio",c[3]/1000.0))
        } })

    fun summary(s: Stats): String {
        val tone = if (s.brightnessMean < 85) "偏暗" else if (s.brightnessMean > 170) "偏亮" else "亮度适中"
        val contrast = if (s.brightnessStd < 28) "低对比" else if (s.brightnessStd > 62) "高对比" else "对比适中"
        val colorful = when {
            s.saturationMean < 24 -> "画面接近黑白"
            s.saturationMean < 70 -> "色彩克制"
            s.saturationMean < 150 -> "色彩浓郁"
            else -> "高饱和"
        }
        val warm = if (s.warmth > 0.08) "整体偏暖" else if (s.warmth < -0.08) "整体偏冷" else "冷暖均衡"
        val parts = mutableListOf("画面$tone（平均亮度 ${s.brightnessMean}/255）", contrast, colorful, warm)
        if (s.dominant.isNotEmpty()) {
            val tops = s.dominant.take(3).joinToString("、") { c -> "#%02x%02x%02x（%d%%）".format(c[0], c[1], c[2], c[3] / 10) }
            parts.add("主色：$tops")
        }
        val shadows = s.histogram.take(5).sum(); val highlights = s.histogram.drop(11).sum()
        if (shadows > 0.4) parts.add("暗部占比高")
        if (highlights > 0.35) parts.add("高光占比高")
        return parts.joinToString("；") + "。"
    }

    private fun mathMin(a: Int, b: Int) = if (a < b) a else b
}
