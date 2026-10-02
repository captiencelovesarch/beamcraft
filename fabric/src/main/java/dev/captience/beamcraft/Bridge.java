package dev.captience.beamcraft;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * The link to BeamNG: newline-delimited JSON over a localhost TCP socket. Minecraft
 * listens, BeamNG connects (and reconnects after a Lua reload). One peer at a time;
 * a new connection replaces the old one.
 *
 * Incoming messages land in {@link #poll()} for the client thread. Outgoing lines go
 * through a writer thread so the game threads never block on the socket.
 */
public final class Bridge {
	private static final Logger LOG = LoggerFactory.getLogger("BeamCraft/Bridge");
	public static final int PORT = Integer.getInteger("beamcraft.port", 47800);

	private static final ConcurrentLinkedQueue<JsonObject> INBOX = new ConcurrentLinkedQueue<>();
	private static final LinkedBlockingQueue<Outgoing> OUTBOX = new LinkedBlockingQueue<>();
	private static final AtomicInteger GENERATION = new AtomicInteger();
	private static volatile Socket peer;
	private static volatile boolean started;

	private record Outgoing(int generation, String line) {}

	private Bridge() {}

	public static synchronized void start() {
		if (started) return;
		started = true;
		Thread accept = new Thread(Bridge::acceptLoop, "BeamCraft-Accept");
		accept.setDaemon(true);
		accept.start();
		Thread writer = new Thread(Bridge::writeLoop, "BeamCraft-Writer");
		writer.setDaemon(true);
		writer.start();
	}

	public static boolean isConnected() {
		Socket s = peer;
		return s != null && !s.isClosed();
	}

	/** Next message from BeamNG, or null. Connection changes arrive as {"t":"_connect"} / {"t":"_disconnect"}. */
	public static JsonObject poll() {
		return INBOX.poll();
	}

	public static void send(JsonObject msg) {
		sendLine(msg.toString());
	}

	public static void sendLine(String jsonLine) {
		if (!isConnected()) return;
		OUTBOX.offer(new Outgoing(GENERATION.get(), jsonLine));
	}

	private static void acceptLoop() {
		while (true) {
			try (ServerSocket server = new ServerSocket(PORT, 4, InetAddress.getLoopbackAddress())) {
				server.setReuseAddress(true);
				LOG.info("Waiting for BeamNG on 127.0.0.1:{}", PORT);
				while (true) {
					Socket s = server.accept();
					s.setTcpNoDelay(true);
					Socket old = peer;
					int gen = GENERATION.incrementAndGet();
					OUTBOX.clear();
					peer = s;
					if (old != null) closeQuietly(old);
					LOG.info("BeamNG connected from {}", s.getRemoteSocketAddress());
					INBOX.add(event("_connect"));
					Thread reader = new Thread(() -> readLoop(s, gen), "BeamCraft-Reader-" + gen);
					reader.setDaemon(true);
					reader.start();
				}
			} catch (IOException e) {
				LOG.error("Bridge server failed, retrying in 2s", e);
				sleep(2000);
			}
		}
	}

	private static void readLoop(Socket s, int gen) {
		try (BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8), 1 << 16)) {
			String line;
			while ((line = in.readLine()) != null) {
				if (line.isEmpty()) continue;
				try {
					INBOX.add(JsonParser.parseString(line).getAsJsonObject());
				} catch (RuntimeException e) {
					LOG.warn("Bad message from BeamNG: {}", line.length() > 200 ? line.substring(0, 200) : line);
				}
			}
		} catch (IOException ignored) {
			// socket closed
		} finally {
			if (peer == s) {
				peer = null;
				LOG.info("BeamNG disconnected");
				INBOX.add(event("_disconnect"));
			}
			closeQuietly(s);
		}
	}

	private static void writeLoop() {
		while (true) {
			try {
				Outgoing first = OUTBOX.poll(1, TimeUnit.SECONDS);
				if (first == null) continue;
				Socket s = peer;
				if (s == null || first.generation != GENERATION.get()) continue;
				StringBuilder batch = new StringBuilder(first.line.length() + 64);
				batch.append(first.line).append('\n');
				Outgoing next;
				while (batch.length() < (1 << 20) && (next = OUTBOX.poll()) != null) {
					if (next.generation == first.generation) batch.append(next.line).append('\n');
				}
				try {
					OutputStream out = s.getOutputStream();
					out.write(batch.toString().getBytes(StandardCharsets.UTF_8));
					out.flush();
				} catch (IOException e) {
					closeQuietly(s);
				}
			} catch (InterruptedException e) {
				return;
			}
		}
	}

	private static JsonObject event(String type) {
		JsonObject o = new JsonObject();
		o.addProperty("t", type);
		return o;
	}

	private static void closeQuietly(Socket s) {
		try {
			s.close();
		} catch (IOException ignored) {
		}
	}

	private static void sleep(long ms) {
		try {
			Thread.sleep(ms);
		} catch (InterruptedException ignored) {
		}
	}
}
