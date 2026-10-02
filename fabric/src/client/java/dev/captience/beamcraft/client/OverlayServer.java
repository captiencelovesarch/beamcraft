package dev.captience.beamcraft.client;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.io.BufferedReader;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CopyOnWriteArrayList;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * A tiny WebSocket server (RFC 6455, just what we need) for BeamNG's UI layer.
 *
 * BeamNG's Chromium UI connects here: we push Minecraft's rendered GUI frames to it as
 * binary messages, and it sends back mouse/keyboard input as JSON text messages while a
 * Minecraft screen (inventory, chat, crafting...) is open. Localhost only.
 */
public final class OverlayServer {
	private static final Logger LOG = LoggerFactory.getLogger("BeamCraft/Overlay");
	public static final int PORT = Integer.getInteger("beamcraft.overlayPort", 47802);
	private static final String GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

	private static final CopyOnWriteArrayList<Client> CLIENTS = new CopyOnWriteArrayList<>();
	/** Input from the overlay page, for the client thread. */
	public static final ConcurrentLinkedQueue<JsonObject> INPUT = new ConcurrentLinkedQueue<>();
	private static volatile boolean started;
	/** Set when a new viewer connects: the next frame must be sent whole. */
	public static volatile boolean needFullFrame = true;

	private OverlayServer() {}

	private static final class Client {
		final Socket socket;
		final OutputStream out;

		Client(Socket socket) throws IOException {
			this.socket = socket;
			this.out = socket.getOutputStream();
		}

		synchronized void sendBinary(byte[] data, int len) throws IOException {
			out.write(0x82);
			if (len < 126) {
				out.write(len);
			} else if (len < 65536) {
				out.write(126);
				out.write(len >>> 8);
				out.write(len & 0xFF);
			} else {
				out.write(127);
				for (int i = 7; i >= 0; i--) out.write((int) (((long) len >>> (8 * i)) & 0xFF));
			}
			out.write(data, 0, len);
			out.flush();
		}

		synchronized void sendControl(int opcode, byte[] payload) throws IOException {
			out.write(0x80 | opcode);
			out.write(payload.length);
			out.write(payload);
			out.flush();
		}
	}

	public static boolean hasViewers() {
		return !CLIENTS.isEmpty();
	}

	public static synchronized void start() {
		if (started) return;
		started = true;
		Thread t = new Thread(OverlayServer::acceptLoop, "BeamCraft-OverlayAccept");
		t.setDaemon(true);
		t.start();
	}

	private static void acceptLoop() {
		while (true) {
			try (ServerSocket server = new ServerSocket(PORT, 4, InetAddress.getLoopbackAddress())) {
				server.setReuseAddress(true);
				LOG.info("Overlay WebSocket on ws://127.0.0.1:{}", PORT);
				while (true) {
					Socket s = server.accept();
					s.setTcpNoDelay(true);
					Thread r = new Thread(() -> serve(s), "BeamCraft-OverlayClient");
					r.setDaemon(true);
					r.start();
				}
			} catch (IOException e) {
				LOG.error("Overlay server failed, retrying", e);
				try {
					Thread.sleep(2000);
				} catch (InterruptedException ignored) {
					return;
				}
			}
		}
	}

	private static void serve(Socket s) {
		Client client = null;
		try {
			InputStream in = s.getInputStream();
			String key = readHandshake(in);
			if (key == null) {
				s.close();
				return;
			}
			String accept = Base64.getEncoder().encodeToString(
				MessageDigest.getInstance("SHA-1").digest((key + GUID).getBytes(StandardCharsets.ISO_8859_1)));
			OutputStream out = s.getOutputStream();
			out.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
				+ "Sec-WebSocket-Accept: " + accept + "\r\n\r\n").getBytes(StandardCharsets.ISO_8859_1));
			out.flush();
			client = new Client(s);
			CLIENTS.add(client);
			needFullFrame = true;
			LOG.info("Overlay viewer connected");
			readFrames(client, new DataInputStream(in));
		} catch (Exception e) {
			// connection dropped
		} finally {
			if (client != null) CLIENTS.remove(client);
			try {
				s.close();
			} catch (IOException ignored) {
			}
			LOG.info("Overlay viewer disconnected");
		}
	}

	private static String readHandshake(InputStream in) throws IOException {
		// read header bytes up to \r\n\r\n without buffering past it
		StringBuilder sb = new StringBuilder();
		int c;
		while ((c = in.read()) != -1) {
			sb.append((char) c);
			if (sb.length() > 16384) return null;
			int n = sb.length();
			if (n >= 4 && sb.charAt(n - 4) == '\r' && sb.charAt(n - 3) == '\n' && sb.charAt(n - 2) == '\r' && sb.charAt(n - 1) == '\n') break;
		}
		BufferedReader r = new BufferedReader(new InputStreamReader(new java.io.ByteArrayInputStream(sb.toString().getBytes(StandardCharsets.ISO_8859_1))));
		String line;
		while ((line = r.readLine()) != null) {
			int colon = line.indexOf(':');
			if (colon > 0 && line.substring(0, colon).trim().equalsIgnoreCase("Sec-WebSocket-Key")) {
				return line.substring(colon + 1).trim();
			}
		}
		return null;
	}

	private static void readFrames(Client client, DataInputStream in) throws IOException {
		java.io.ByteArrayOutputStream message = new java.io.ByteArrayOutputStream();
		int messageOpcode = 0;
		while (true) {
			int b0 = in.readUnsignedByte();
			int b1 = in.readUnsignedByte();
			boolean fin = (b0 & 0x80) != 0;
			int opcode = b0 & 0x0F;
			boolean masked = (b1 & 0x80) != 0;
			long len = b1 & 0x7F;
			if (len == 126) len = in.readUnsignedShort();
			else if (len == 127) len = in.readLong();
			if (len > (1 << 20)) throw new IOException("frame too large");
			byte[] mask = new byte[4];
			if (masked) in.readFully(mask);
			byte[] payload = new byte[(int) len];
			in.readFully(payload);
			if (masked) for (int i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
			switch (opcode) {
				case 0x8 -> {
					client.sendControl(0x8, new byte[0]);
					return;
				}
				case 0x9 -> client.sendControl(0xA, payload);
				case 0xA -> {
				}
				default -> {
					if (opcode != 0) {
						messageOpcode = opcode;
						message.reset();
					}
					message.write(payload);
					if (fin && messageOpcode == 0x1) {
						String text = message.toString(StandardCharsets.UTF_8);
						try {
							INPUT.add(JsonParser.parseString(text).getAsJsonObject());
						} catch (RuntimeException e) {
							LOG.debug("Bad overlay message {}", text);
						}
					}
				}
			}
		}
	}

	public static void broadcast(byte[] data, int len) {
		for (Client c : CLIENTS) {
			try {
				c.sendBinary(data, len);
			} catch (IOException e) {
				CLIENTS.remove(c);
				try {
					c.socket.close();
				} catch (IOException ignored) {
				}
			}
		}
	}
}
