package dev.captience.beamcraft.client;

import com.mojang.blaze3d.buffers.GpuBuffer;
import com.mojang.blaze3d.buffers.GpuBufferSlice;
import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.textures.GpuTexture;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayDeque;
import java.util.Comparator;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Stream;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Minecraft draws its own GUI, hand and screen effects over a transparent background
 * (the world pass is skipped); this copies each finished frame off the GPU and hands
 * the part that changed to BeamNG, which draws it over the game with imgui.
 *
 * BeamNG's Chromium UI tops out well below the game's frame rate (measured ~37 fps
 * while the game ran at 104), so frames don't go through it. Instead the changed
 * 128 px tiles of a frame are packed into one atlas PNG (cells of 130 px: each tile
 * with a 1 px apron of its neighbours) in a RAM disk that BeamNG sees at
 * /beamcraft/ov (a symlink in its userfolder), and the frame message on the raw
 * socket says where each tile went:
 *
 *   "W,H,T,full,atlas,cols;tx,ty,k;tx,ty,-;..."   (k = cell index in the atlas,
 *                                                   '-' = empty tile, atlas '-' = none)
 *
 * One file per frame, not one per tile: BeamNG's texture load is mostly fixed cost
 * (measured: 1 tile 0.8 ms, a 56-tile atlas 4 ms), and an enchanted item's glint in
 * first person changes ~50 tiles every frame. Files are deleted a few seconds later;
 * BeamNG has them on the GPU by then.
 */
public final class OverlayCapture {
	private static final Logger LOG = LoggerFactory.getLogger("BeamCraft/Overlay");
	private static final int SLOTS = 3;
	public static final int TILE = 128;
	private static final long FILE_TTL_NS = 3_000_000_000L;

	private static final GpuBuffer[] BUFFERS = new GpuBuffer[SLOTS];
	private static long bufferSize;
	private static int nextSlot;
	private static final AtomicInteger IN_FLIGHT = new AtomicInteger();

	private static final ExecutorService ENCODER = Executors.newSingleThreadExecutor(r -> {
		Thread t = new Thread(r, "BeamCraft-OverlayEncoder");
		t.setDaemon(true);
		return t;
	});
	private static final AtomicInteger ENCODE_QUEUE = new AtomicInteger();

	// tile files
	private static volatile Path tileDir;
	private static final ArrayDeque<Object[]> WRITTEN = new ArrayDeque<>(); // {Long nanos, Path}
	private static long fileSeq;
	private static long statNs, statTiles;
	private static int statFrames;

	// encoder-thread state
	private static int[] prev;
	private static int prevW, prevH;
	private static ByteBuffer pngBuf = ByteBuffer.allocateDirect(1 << 20);
	private static byte[] rawBuf = new byte[1 << 20];
	private static final int CELL = TILE + 2;

	private OverlayCapture() {}

	/**
	 * BeamNG told us its userfolder: put the tile directory on a RAM disk and link it in
	 * as <userfolder>/beamcraft/ov (falls back to a plain folder there).
	 */
	public static void setUserPath(Path userPath) {
		if (userPath == null) return;
		Path link = userPath.resolve("beamcraft").resolve("ov");
		Path shm = Path.of("/dev/shm/beamcraft_ov_" + ProcessHandle.current().pid());
		Path dir = link;
		try {
			Files.createDirectories(link.getParent());
			if (Files.isDirectory(Path.of("/dev/shm"))) {
				Files.createDirectories(shm);
				if (Files.isSymbolicLink(link)) {
					Path old = Files.readSymbolicLink(link);
					if (!old.equals(shm)) {
						deleteTree(old);
						Files.delete(link);
					}
				} else if (Files.exists(link, LinkOption.NOFOLLOW_LINKS)) {
					deleteTree(link);
				}
				if (!Files.exists(link, LinkOption.NOFOLLOW_LINKS)) Files.createSymbolicLink(link, shm);
				dir = shm;
			} else {
				Files.createDirectories(link);
			}
			// leftovers from an earlier run
			try (Stream<Path> s = Files.list(dir)) {
				s.forEach(p -> { try { Files.deleteIfExists(p); } catch (IOException ignored) {} });
			}
		} catch (IOException e) {
			LOG.warn("Overlay tile folder {} unusable", link, e);
		}
		tileDir = dir;
		LOG.info("Overlay tiles in {} (BeamNG: /beamcraft/ov)", dir);
	}

	private static void deleteTree(Path p) {
		if (!Files.exists(p, LinkOption.NOFOLLOW_LINKS)) return;
		try (Stream<Path> s = Files.walk(p)) {
			s.sorted(Comparator.reverseOrder()).forEach(q -> { try { Files.deleteIfExists(q); } catch (IOException ignored) {} });
		} catch (IOException ignored) {
		}
	}

	/** Render thread, end of every frame. */
	public static void afterFrame(RenderTarget target) {
		if (!BeamCraftClient.HEADLESS || !OverlayServer.hasRawViewers() || tileDir == null) return;
		// BeamNG's Lua pulls: capture only when it has asked for a frame
		if (OverlayServer.RAW_REQUESTS.get() <= 0) return;
		if (IN_FLIGHT.get() >= SLOTS || ENCODE_QUEUE.get() >= 2) return;
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
		OverlayServer.RAW_REQUESTS.decrementAndGet();
		IN_FLIGHT.incrementAndGet();
		RenderSystem.getDevice().createCommandEncoder().copyTextureToBuffer(tex, buf, 0L, () -> {
			try (GpuBufferSlice.MappedView view = buf.map(true, false)) {
				int[] px = takeArray(w * h);
				view.data().duplicate().order(ByteOrder.LITTLE_ENDIAN).asIntBuffer().get(px, 0, w * h);
				ENCODE_QUEUE.incrementAndGet();
				ENCODER.execute(() -> {
					try {
						long t0 = System.nanoTime();
						encodeAndSend(px, w, h);
						statNs += System.nanoTime() - t0;
						if (++statFrames >= 600) {
							LOG.info("Overlay: {} frames, encode {} ms avg, {} tiles/frame", statFrames,
								String.format("%.2f", statNs / 1e6 / statFrames), String.format("%.1f", statTiles / (double) statFrames));
							statFrames = 0;
							statNs = 0;
							statTiles = 0;
						}
					} catch (Throwable t) {
						LOG.warn("Overlay encode failed", t);
						OverlayServer.needFullFrame = true;
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

	// full-frame arrays are 15 MB at 1440p: recycle them instead of feeding the GC
	private static final java.util.concurrent.ConcurrentLinkedQueue<int[]> POOL = new java.util.concurrent.ConcurrentLinkedQueue<>();

	private static int[] takeArray(int n) {
		int[] a;
		while ((a = POOL.poll()) != null) if (a.length == n) return a;
		return new int[n];
	}

	/**
	 * px = ABGR ints (RGBA bytes), rows bottom-up as OpenGL reads them, colour
	 * premultiplied by alpha. Worked on in place (no flipped copy): tile row y (top-down)
	 * is source row h-1-y. Fully transparent pixels count as equal whatever their colour.
	 */
	private static void encodeAndSend(int[] cur, int w, int h) throws IOException {
		sweepOldFiles();
		boolean full = OverlayServer.needFullFrame || prev == null || prevW != w || prevH != h;
		if (full) OverlayServer.needFullFrame = false;
		int[] old = full ? null : prev;

		StringBuilder entries = new StringBuilder(256);
		int tilesX = (w + TILE - 1) / TILE, tilesY = (h + TILE - 1) / TILE;
		int[] packed = new int[tilesX * tilesY];
		int n = 0;
		for (int ty = 0; ty < tilesY; ty++) {
			int y0 = ty * TILE, y1 = Math.min(h, y0 + TILE);
			for (int tx = 0; tx < tilesX; tx++) {
				int x0 = tx * TILE, x1 = Math.min(w, x0 + TILE);
				if (!full && !tileChanged(cur, old, w, h, x0, y0, x1, y1)) continue;
				boolean empty = isEmpty(cur, w, h, x0, y0, x1, y1);
				if (full && empty) continue; // BeamNG starts from a clear screen
				entries.append(';').append(tx).append(',').append(ty).append(',');
				if (empty) {
					entries.append('-');
				} else {
					entries.append(n);
					packed[n++] = ty * tilesX + tx;
				}
			}
		}
		int cols = Math.max(1, (int) Math.ceil(Math.sqrt(n)));
		String atlas = n == 0 ? "-" : writeAtlas(cur, w, h, tilesX, packed, n, cols);
		StringBuilder msg = new StringBuilder(64 + entries.length());
		msg.append(w).append(',').append(h).append(',').append(TILE).append(',').append(full ? 1 : 0)
			.append(',').append(atlas).append(',').append(cols).append(entries);
		if (prev != null) POOL.add(prev);
		prev = cur;
		prevW = w;
		prevH = h;
		byte[] raw = msg.toString().getBytes(StandardCharsets.US_ASCII);
		OverlayServer.broadcastRaw(raw, raw.length);
	}

	private static boolean isEmpty(int[] cur, int w, int h, int x0, int y0, int x1, int y1) {
		for (int y = y0; y < y1; y++) {
			int row = (h - 1 - y) * w;
			for (int x = x0; x < x1; x++) if ((cur[row + x] >>> 24) != 0) return false;
		}
		return true;
	}

	private static boolean tileChanged(int[] cur, int[] old, int w, int h, int x0, int y0, int x1, int y1) {
		for (int y = y0; y < y1; y++) {
			int row = (h - 1 - y) * w;
			int from = row + x0, to = row + x1;
			// Arrays.mismatch is a vectorized JIT intrinsic: the per-pixel loop it
			// replaces was the overlay encoder's whole cost (~60% of a core)
			while (from < to) {
				int i = java.util.Arrays.mismatch(cur, from, to, old, from, to);
				if (i < 0) break;
				int a = cur[from + i], b = old[from + i];
				// fully transparent either way: no visible change
				if ((a >>> 24) != 0 || (b >>> 24) != 0) return true;
				from += i + 1;
			}
		}
		return false;
	}

	/**
	 * The frame's changed tiles packed into one PNG with stored (uncompressed) deflate
	 * blocks, cols cells per row, cell k at (k % cols, k / cols). Each cell holds its
	 * tile plus a 1 px apron of the neighbouring pixels (edge pixels repeated at the
	 * frame border): BeamNG samples with filtering, which drew seams between tiles when
	 * a tile's edge blended with whatever lay next to it. Colour is un-premultiplied for
	 * imgui's straight-alpha blending.
	 */
	private static String writeAtlas(int[] cur, int w, int h, int tilesX, int[] packed, int n, int cols) throws IOException {
		int rows = (n + cols - 1) / cols;
		int aw = cols * CELL, ah = rows * CELL;
		int rowLen = 1 + aw * 4;
		int rawLen = rowLen * ah;
		if (rawBuf.length < rawLen) rawBuf = new byte[rawLen];
		byte[] raw = rawBuf;
		for (int r = 0; r < ah; r++) raw[r * rowLen] = 0; // filter: none
		for (int k = 0; k < n; k++) {
			int tx = packed[k] % tilesX, ty = packed[k] / tilesX;
			int x0 = tx * TILE, y0 = ty * TILE;
			int tw0 = Math.min(TILE, w - x0), th0 = Math.min(TILE, h - y0);
			int cx = (k % cols) * CELL, cy = (k / cols) * CELL;
			for (int yy = 0; yy < th0 + 2; yy++) {
				int y = Math.max(0, Math.min(h - 1, y0 - 1 + yy));
				int row = (h - 1 - y) * w;
				int p = (cy + yy) * rowLen + 1 + cx * 4;
				for (int xx = 0; xx < tw0 + 2; xx++) {
					int c = cur[row + Math.max(0, Math.min(w - 1, x0 - 1 + xx))];
					int a = c >>> 24;
					int r = c & 0xFF, g = (c >>> 8) & 0xFF, bl = (c >>> 16) & 0xFF;
					if (a > 0 && a < 255) {
						r = Math.min(255, (r * 255 + a / 2) / a);
						g = Math.min(255, (g * 255 + a / 2) / a);
						bl = Math.min(255, (bl * 255 + a / 2) / a);
					}
					raw[p++] = (byte) r;
					raw[p++] = (byte) g;
					raw[p++] = (byte) bl;
					raw[p++] = (byte) a;
				}
			}
		}
		// zlib stream of stored blocks (max 65535 bytes each)
		int blocks = (rawLen + 65534) / 65535;
		int need = 64 + rawLen + blocks * 5;
		if (pngBuf.capacity() < need) pngBuf = ByteBuffer.allocateDirect(need + (need >> 2));
		ByteBuffer b = pngBuf;
		b.clear();
		b.order(ByteOrder.BIG_ENDIAN);
		b.put(new byte[] {(byte) 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'});
		int ihdr = b.position();
		b.putInt(13).put((byte) 'I').put((byte) 'H').put((byte) 'D').put((byte) 'R')
			.putInt(aw).putInt(ah).put((byte) 8).put((byte) 6).put((byte) 0).put((byte) 0).put((byte) 0);
		crc(b, ihdr + 4, b.position());
		int idatLen = 2 + rawLen + blocks * 5 + 4;
		int idat = b.position();
		b.putInt(idatLen).put((byte) 'I').put((byte) 'D').put((byte) 'A').put((byte) 'T');
		b.put((byte) 0x78).put((byte) 0x01);
		for (int off = 0; off < rawLen; off += 65535) {
			int len = Math.min(65535, rawLen - off);
			b.put((byte) (off + len >= rawLen ? 1 : 0));
			b.put((byte) len).put((byte) (len >>> 8)).put((byte) ~len).put((byte) (~len >>> 8));
			b.put(raw, off, len);
		}
		ADLER.reset();
		ADLER.update(raw, 0, rawLen);
		b.putInt((int) ADLER.getValue());
		crc(b, idat + 4, b.position());
		int iend = b.position();
		b.putInt(0).put((byte) 'I').put((byte) 'E').put((byte) 'N').put((byte) 'D');
		crc(b, iend + 4, b.position());
		b.flip();
		statTiles += n;
		String name = "a" + Long.toString(fileSeq++, 36) + ".png";
		Path file = tileDir.resolve(name);
		try (FileChannel ch = FileChannel.open(file, StandardOpenOption.CREATE, StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING)) {
			while (b.hasRemaining()) ch.write(b);
		}
		WRITTEN.addLast(new Object[] {System.nanoTime(), file});
		return name;
	}

	private static final java.util.zip.CRC32 CRC = new java.util.zip.CRC32();
	private static final java.util.zip.Adler32 ADLER = new java.util.zip.Adler32();

	/** Append the CRC of bytes [from, to) of b (chunk type + data). */
	private static void crc(ByteBuffer b, int from, int to) {
		CRC.reset();
		ByteBuffer d = b.duplicate();
		d.position(from).limit(to);
		CRC.update(d);
		b.putInt((int) CRC.getValue());
	}

	private static void sweepOldFiles() {
		long now = System.nanoTime();
		while (!WRITTEN.isEmpty() && now - (Long) WRITTEN.peekFirst()[0] > FILE_TTL_NS) {
			try {
				Files.deleteIfExists((Path) WRITTEN.pollFirst()[1]);
			} catch (IOException ignored) {
			}
		}
	}
}
