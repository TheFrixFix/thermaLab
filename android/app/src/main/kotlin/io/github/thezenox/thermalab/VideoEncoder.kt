package io.github.thezenox.thermalab

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

/**
 * Encodes RGBA frames handed over from Flutter into an H.264 MP4 file, with
 * an optional AAC microphone track.
 *
 * Frames are drawn onto the encoder's input surface; a background thread
 * drains the encoder into the muxer. Timestamps come from the frame calls,
 * so a variable frame rate is recorded as it happened. The audio thread
 * stamps its samples on the same monotonic clock, so both tracks line up.
 */
class VideoEncoder(
    private val path: String,
    private val width: Int,
    private val height: Int,
    fps: Int,
    withAudio: Boolean,
) {
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val surface: Surface
    private val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    private val audio: AudioTrackEncoder? = if (withAudio) AudioTrackEncoder.create() else null
    private val muxer = SyncedMuxer(path, if (audio != null) 2 else 1)
    private val drainThread: Thread
    @Volatile private var finished = false

    /** Whether the file gets a sound track (false if the microphone failed). */
    val hasAudio: Boolean get() = audio != null

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, width * height * 6)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = codec.createInputSurface()
        codec.start()
        drainThread = Thread({ drain() }, "t2s-video-drain").apply { start() }
        audio?.start(muxer)
    }

    /** Draws one RGBA frame (width * height * 4 bytes). */
    fun addFrame(rgba: ByteArray) {
        if (finished) return
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
        val canvas = surface.lockHardwareCanvas()
        try {
            canvas.drawBitmap(bitmap, 0f, 0f, null)
        } finally {
            surface.unlockCanvasAndPost(canvas)
        }
    }

    /** Finishes the file. Blocks until the encoders have flushed. */
    fun finish(): String {
        if (!finished) {
            codec.signalEndOfInputStream()
            drainThread.join(5000)
            finished = true
            audio?.finish()
            try { codec.stop() } catch (e: Exception) { Log.w(TAG, "codec stop", e) }
            codec.release()
            surface.release()
            muxer.finish()
            bitmap.recycle()
        }
        return path
    }

    private fun drain() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val index = try {
                codec.dequeueOutputBuffer(info, 10_000)
            } catch (e: IllegalStateException) {
                return
            }
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                    muxer.addTrack(codec.outputFormat, video = true)
                index >= 0 -> {
                    val buffer = codec.getOutputBuffer(index)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        info.size = 0
                    }
                    if (info.size > 0 && buffer != null) {
                        muxer.write(video = true, buffer, info)
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    companion object {
        const val TAG = "T2sVideoEncoder"
    }
}

/**
 * MediaMuxer that starts once every track has its format and holds back
 * samples until then. Sound recorded before the first video frame is
 * dropped, so the film starts with picture and sound together.
 */
private class SyncedMuxer(path: String, private var trackCount: Int) {
    private class Sample(val video: Boolean, val data: ByteBuffer, val info: MediaCodec.BufferInfo)

    private val muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private var videoTrack = -1
    private var audioTrack = -1
    private var added = 0
    private var started = false
    private var stopped = false
    private var firstVideoUs = -1L
    private val pending = ArrayList<Sample>()

    @Synchronized
    fun addTrack(format: MediaFormat, video: Boolean) {
        if (stopped) return
        val track = muxer.addTrack(format)
        if (video) videoTrack = track else audioTrack = track
        if (++added == trackCount) {
            muxer.start()
            started = true
            flush()
        }
    }

    /** The sound track failed before it had a format: record picture only. */
    @Synchronized
    fun dropAudio() {
        if (stopped || started || audioTrack >= 0) return
        trackCount--
        pending.removeAll { !it.video }
        if (added == trackCount) {
            muxer.start()
            started = true
            flush()
        }
    }

    @Synchronized
    fun write(video: Boolean, buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        if (stopped) return
        if (video && firstVideoUs < 0) firstVideoUs = info.presentationTimeUs
        if (!started || (!video && firstVideoUs < 0)) {
            // Keep a copy: the codec reuses its buffer.
            buffer.position(info.offset)
            buffer.limit(info.offset + info.size)
            val copy = ByteBuffer.allocate(info.size).put(buffer)
            copy.flip()
            val i = MediaCodec.BufferInfo().apply {
                set(0, info.size, info.presentationTimeUs, info.flags)
            }
            pending.add(Sample(video, copy, i))
            if (started) flush()
            return
        }
        flush()
        writeNow(video, buffer, info)
    }

    private fun flush() {
        if (!started || pending.isEmpty()) return
        val keep = ArrayList<Sample>()
        for (s in pending) {
            if (!s.video && firstVideoUs < 0) keep.add(s) else writeNow(s.video, s.data, s.info)
        }
        pending.clear()
        pending.addAll(keep)
    }

    private fun writeNow(video: Boolean, buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        if (!video && info.presentationTimeUs < firstVideoUs) return
        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)
        muxer.writeSampleData(if (video) videoTrack else audioTrack, buffer, info)
    }

    @Synchronized
    fun finish() {
        if (stopped) return
        stopped = true
        if (started) {
            try { muxer.stop() } catch (e: Exception) { Log.w(VideoEncoder.TAG, "muxer stop", e) }
        }
        muxer.release()
    }
}

/** Microphone → AAC on its own thread. */
private class AudioTrackEncoder private constructor(
    private val record: AudioRecord,
    private val codec: MediaCodec,
) {
    @Volatile private var stopping = false
    private var thread: Thread? = null

    fun start(muxer: SyncedMuxer) {
        record.startRecording()
        codec.start()
        thread = Thread({ loop(muxer) }, "t2s-audio").apply { start() }
    }

    fun finish() {
        stopping = true
        thread?.join(3000)
        try { record.stop() } catch (e: Exception) { Log.w(VideoEncoder.TAG, "audio stop", e) }
        record.release()
        try { codec.stop() } catch (e: Exception) { Log.w(VideoEncoder.TAG, "audio codec stop", e) }
        codec.release()
    }

    private fun loop(muxer: SyncedMuxer) {
        val info = MediaCodec.BufferInfo()
        var startUs = -1L
        var frames = 0L
        var eosSent = false
        try {
            while (true) {
                if (!eosSent) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buf = codec.getInputBuffer(inIndex)!!
                        buf.clear()
                        val read = record.read(buf, minOf(buf.capacity(), 4096))
                        if (read < 0) throw IllegalStateException("microphone read $read")
                        if (startUs < 0) {
                            // First read: the samples ended just now.
                            startUs = System.nanoTime() / 1000 -
                                (read.coerceAtLeast(0) / BYTES_PER_FRAME) * 1_000_000L / SAMPLE_RATE
                        }
                        val pts = startUs + frames * 1_000_000L / SAMPLE_RATE
                        if (read > 0) frames += read / BYTES_PER_FRAME
                        if (stopping) {
                            codec.queueInputBuffer(inIndex, 0, read.coerceAtLeast(0), pts,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            eosSent = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, read.coerceAtLeast(0), pts, 0)
                        }
                    }
                }
                while (true) {
                    val outIndex = codec.dequeueOutputBuffer(info, if (eosSent) 10_000 else 0)
                    if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER) break
                    if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        muxer.addTrack(codec.outputFormat, video = false)
                        continue
                    }
                    if (outIndex < 0) continue
                    val out = codec.getOutputBuffer(outIndex)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (info.size > 0 && out != null) muxer.write(video = false, out, info)
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        } catch (e: Exception) {
            Log.w(VideoEncoder.TAG, "audio", e)
            muxer.dropAudio()
        }
    }

    companion object {
        private const val SAMPLE_RATE = 44_100
        private const val BYTES_PER_FRAME = 2 // 16-bit mono

        /** Null when the microphone or the encoder cannot be opened. */
        @SuppressLint("MissingPermission") // checked by MainActivity
        fun create(): AudioTrackEncoder? {
            var record: AudioRecord? = null
            return try {
                val min = AudioRecord.getMinBufferSize(
                    SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                record = AudioRecord(
                    MediaRecorder.AudioSource.CAMCORDER, SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    maxOf(min, 8192) * 2)
                if (record.state != AudioRecord.STATE_INITIALIZED) {
                    record.release()
                    return null
                }
                val format = MediaFormat.createAudioFormat(
                    MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, 96_000)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192)
                }
                val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                AudioTrackEncoder(record, codec)
            } catch (e: Exception) {
                Log.w(VideoEncoder.TAG, "no microphone", e)
                record?.release()
                null
            }
        }
    }
}
