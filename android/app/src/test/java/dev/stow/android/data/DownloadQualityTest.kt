package dev.stow.android.data

import org.junit.Assert.assertEquals
import org.junit.Test

class DownloadQualityTest {
    @Test fun capsTheResolutionAndPrefersHardwareCodecs() {
        assertEquals("res:1080,fps,vcodec:h264,acodec:m4a", DownloadQuality.P1080.formatSort)
        assertEquals("res:720,fps,vcodec:h264,acodec:m4a", DownloadQuality.P720.formatSort)
    }

    @Test fun bestHasNoCap() {
        assertEquals("res,fps,vcodec:h264,acodec:m4a", DownloadQuality.BEST.formatSort)
    }
}
