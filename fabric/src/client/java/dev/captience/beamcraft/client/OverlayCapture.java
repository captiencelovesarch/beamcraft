package dev.captience.beamcraft.client;

import com.mojang.blaze3d.buffers.GpuBuffer;
import com.mojang.blaze3d.buffers.GpuBufferSlice;
import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.textures.GpuTexture;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Minecraft draws its own GUI, hand and screen effects over a transparent background
 * (the world pass is skipped); this copies each finished frame off the GPU and streams
 * the part that changed to BeamNG's UI, which paints it over the game.
 *
 * Message format (little-endian): "BCF1", u16 fullW, u16 fullH, u16 x, u16 y, u16 w,
 * u16 h, u32 frameId, then w*h RGBA pixels (straight alpha, rows top-down).
 */
public final class OverlayCapture {
	private static final Logger LOG = LoggerFactory.getLogger("BeamCraft/Overlay");
	private static final int SLOTS = 3;
	// capture every frame; the frame rate itself follows BeamNG's (BeamCraftClient.targetFps)
	private static final long MIN_INTERVAL_NS = Long.getLong("beamcraft.overlayIntervalMs", 0L) * 1_000_000L;

	private static final GpuBuffer[] BUFFERS = new GpuBuffer[SLOTS];
	private static long bufferSize;
	private static int nextSlot;
	private static final AtomicInteger IN_FLIGHT = new AtomicInteger();
	private static long lastCapture;

	private static final ExecutorService ENCODER = Executors.newSingleThreadExecutor(r -> {
		Thread t = new Thread(r, "BeamCraft-OverlayEncoder");
		t.setDaemon(true);
		return t;
	});
	private static final AtomicInteger ENCODE_QUEUE = new AtomicInteger();

	// encoder-thread state
	private static int[] prev;
	private static int prevW, prevH;
	private static int frameId;
	private static byte[] out = new byte[0];

	private OverlayCapture() {}

	/** Render thread, end of every frame. */
	public static void afterFrame(RenderTarget target) {
		if (!BeamCraftClient.HEADLESS || !OverlayServer.hasViewers()) return;
		long now = System.nanoTime();
		if (now - lastCapture < MIN_INTERVAL_NS || IN_FLIGHT.get() >= 3 || ENCODE_QUEUE.get() >= 3) return;
		GpuTexture tex = target.getColorTexture();
		if (tex == null) return;
		final int w = target.width, h = target.height;
		long size = (long) w * h * 4;
		if (size != bufferSize) {
			if (IN_FLIGHT.get() > 0) return; // let pending copies finish before swapping buffers
			for (int i = 0; i < SLOTS; i++) {
				if (BUFFERS[i] != null) BUFFERS[i].close();
				BUFFERS[i] = RenderSystem.getDevice().createBuffer(() -> "BeamCraft overlay",
					GpuBuffer.USAGE_MAP_READ | GpuBuffer.USAGE_COPY_DST, size);
			}
			bufferSize = size;
		}
		final GpuBuffer buf = BUFFERS[nextSlot++ % SLOTS];
		lastCapture = now;
		IN_FLIGHT.incrementAndGet();
		RenderSystem.getDevice().createCommandEncoder().copyTextureToBuffer(tex, buf, 0L, () -> {
			try (GpuBufferSlice.MappedView view = buf.map(true, false)) {
				int[] px = new int[w * h];
				view.data().duplicate().order(ByteOrder.LITTLE_ENDIAN).asIntBuffer().get(px, 0, w * h);
				ENCODE_QUEUE.incrementAndGet();
				ENCODER.execute(() -> {
					try {
						encodeAndSend(px, w, h);
					} catch (Throwable t) {
						LOG.warn("Overlay encode failed", t);
					} finally {
						ENCODE_QUEUE.decrementAndGet();
					}
				});
			} catch (Throwable t) {
				LOG.warn("Overlay readback failed", t);
			} finally {
				IN_FLIGHT.decrementAndGet();
			}
		}, 0);
	}

	private static final int TILE = 32;

	/** px = ABGR ints (RGBA bytes), rows bottom-up, colour premultiplied by alpha. */
	private static void encodeAndSend(int[] px, int w, int h) {
		// flip to top-down
		int[] cur = new int[w * h];
		for (int y = 0; y < h; y++) System.arraycopy(px, (h - 1 - y) * w, cur, y * w, w);

		boolean full = OverlayServer.needFullFrame || prev == null || prevW != w || prevH != h;
		int[] old = prev;
		prev = cur;
		prevW = w;
		prevH = h;
		if (full) {
			OverlayServer.needFullFrame = false;
			sendRect(cur, w, h, 0, 0, w, h);
			return;
		}
		// Changed 32x32 tiles, merged into horizontal runs per tile row: the hand and
		// the hotbar changing together shouldn't resend the whole screen between them.
		int tilesX = (w + TILE - 1) / TILE, tilesY = (h + TILE - 1) / TILE;
		for (int ty = 0; ty < tilesY; ty++) {
			int y0 = ty * TILE, y1 = Math.min(h, y0 + TILE);
			int runStart = -1;
			for (int tx = 0; tx <= tilesX; tx++) {
				boolean changed = tx < tilesX && tileChanged(cur, old, w, tx * TILE, y0, Math.min(w, tx * TILE + TILE), y1);
				if (changed && runStart < 0) runStart = tx;
				if (!changed && runStart >= 0) {
					int x0 = runStart * TILE, x1 = Math.min(w, tx * TILE);
					sendRect(cur, w, h, x0, y0, x1 - x0, y1 - y0);
					runStart = -1;
				}
			}
		}
	}

	private static boolean tileChanged(int[] cur, int[] old, int w, int x0, int y0, int x1, int y1) {
		for (int y = y0; y < y1; y++) {
			int row = y * w;
			for (int x = x0; x < x1; x++) {
				if (cur[row + x] != old[row + x]) return true;
			}
		}
		return false;
	}

	private static void sendRect(int[] cur, int w, int h, int x0, int y0, int rw, int rh) {
		int len = 20 + rw * rh * 4;
		if (out.length < len) out = new byte[len];
		byte[] o = out;
		o[0] = 'B';
		o[1] = 'C';
		o[2] = 'F';
		o[3] = '1';
		putShort(o, 4, w);
		putShort(o, 6, h);
		putShort(o, 8, x0);
		putShort(o, 10, y0);
		putShort(o, 12, rw);
		putShort(o, 14, rh);
		frameId++;
		o[16] = (byte) frameId;
		o[17] = (byte) (frameId >>> 8);
		o[18] = (byte) (frameId >>> 16);
		o[19] = (byte) (frameId >>> 24);
		int p = 20;
		for (int y = y0; y < y0 + rh; y++) {
			int row = y * w;
			for (int x = x0; x < x0 + rw; x++) {
				int c = cur[row + x];
				int a = c >>> 24;
				int r = c & 0xFF, g = (c >>> 8) & 0xFF, b = (c >>> 16) & 0xFF;
				if (a > 0 && a < 255) {
					// un-premultiply: GUI blending over transparent black leaves colour * alpha
					r = Math.min(255, r * 255 / a);
					g = Math.min(255, g * 255 / a);
					b = Math.min(255, b * 255 / a);
				}
				o[p++] = (byte) r;
				o[p++] = (byte) g;
				o[p++] = (byte) b;
				o[p++] = (byte) a;
			}
		}
		if (OverlayServer.hasWebSocketViewers()) OverlayServer.broadcast(o, len);
		if (OverlayServer.hasRawViewers()) {
			// already shaped as the JS hook's argument list, so BeamNG's Lua passes it on as-is
			byte[] head = ("[\"" + w + "," + h + "," + x0 + "," + y0 + "," + rw + "," + rh + "|").getBytes(StandardCharsets.US_ASCII);
			byte[] enc = Base64.getEncoder().encode(java.util.Arrays.copyOfRange(o, 20, len));
			byte[] raw = new byte[head.length + enc.length + 2];
			System.arraycopy(head, 0, raw, 0, head.length);
			System.arraycopy(enc, 0, raw, head.length, enc.length);
			raw[raw.length - 2] = '"';
			raw[raw.length - 1] = ']';
			OverlayServer.broadcastRaw(raw, raw.length);
		}
	}

	private static void putShort(byte[] o, int at, int v) {
		o[at] = (byte) v;
		o[at + 1] = (byte) (v >>> 8);
	}
}
