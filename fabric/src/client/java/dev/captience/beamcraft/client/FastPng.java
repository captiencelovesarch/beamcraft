package dev.captience.beamcraft.client;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.zip.CRC32;
import java.util.zip.Deflater;
import java.util.zip.DeflaterOutputStream;

/** Fast, lossless RGBA PNG for one changed overlay rectangle. */
final class FastPng {
	private static final byte[] SIGNATURE = {(byte) 137, 80, 78, 71, 13, 10, 26, 10};

	private FastPng() {}

	/** Source pixels are top-down ABGR ints, premultiplied by alpha. */
	static byte[] encode(int[] pixels, int stride, int x, int y, int width, int height) throws IOException {
		ByteArrayOutputStream compressed = new ByteArrayOutputStream(width * height / 2);
		Deflater deflater = new Deflater(Deflater.BEST_SPEED);
		try (DeflaterOutputStream z = new DeflaterOutputStream(compressed, deflater)) {
			byte[] row = new byte[1 + width * 4]; // PNG filter 0: no filtering
			for (int py = y; py < y + height; py++) {
				int p = 1;
				for (int px = x; px < x + width; px++) {
					int c = pixels[py * stride + px];
					int a = c >>> 24;
					int r = c & 255, g = (c >>> 8) & 255, b = (c >>> 16) & 255;
					if (a > 0 && a < 255) {
						r = Math.min(255, (r * 255 + a / 2) / a);
						g = Math.min(255, (g * 255 + a / 2) / a);
						b = Math.min(255, (b * 255 + a / 2) / a);
					}
					row[p++] = (byte) r;
					row[p++] = (byte) g;
					row[p++] = (byte) b;
					row[p++] = (byte) a;
				}
				z.write(row);
			}
		} finally {
			deflater.end();
		}
		ByteArrayOutputStream png = new ByteArrayOutputStream(compressed.size() + 64);
		png.write(SIGNATURE);
		ByteArrayOutputStream header = new ByteArrayOutputStream(13);
		DataOutputStream ihdr = new DataOutputStream(header);
		ihdr.writeInt(width);
		ihdr.writeInt(height);
		ihdr.writeByte(8); // 8 bits per channel
		ihdr.writeByte(6); // RGBA
		ihdr.writeByte(0); // zlib compression
		ihdr.writeByte(0); // adaptive filtering
		ihdr.writeByte(0); // no interlace
		writeChunk(png, "IHDR", header.toByteArray());
		writeChunk(png, "IDAT", compressed.toByteArray());
		writeChunk(png, "IEND", new byte[0]);
		return png.toByteArray();
	}

	private static void writeChunk(ByteArrayOutputStream output, String name, byte[] data) throws IOException {
		DataOutputStream stream = new DataOutputStream(output);
		byte[] type = name.getBytes(StandardCharsets.US_ASCII);
		stream.writeInt(data.length);
		stream.write(type);
		stream.write(data);
		CRC32 crc = new CRC32();
		crc.update(type);
		crc.update(data);
		stream.writeInt((int) crc.getValue());
	}
}
