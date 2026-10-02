package dev.captience.beamcraft.client;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.awt.image.BufferedImage;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import javax.imageio.ImageIO;
import net.minecraft.client.Minecraft;
import net.minecraft.client.color.block.BlockTintSource;
import net.minecraft.client.renderer.block.dispatch.BlockStateModel;
import net.minecraft.client.renderer.block.dispatch.BlockStateModelPart;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.client.resources.model.geometry.BakedQuad;
import net.minecraft.core.Direction;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.server.packs.resources.ResourceManager;
import net.minecraft.util.RandomSource;
import net.minecraft.world.item.BlockItem;
import net.minecraft.world.item.Item;
import net.minecraft.world.level.block.state.BlockState;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Everything BeamNG needs to draw a Minecraft HUD and Steve: the vanilla HUD sprites,
 * the pixel font, the player skin, and an icon per item (an isometric cube for full
 * blocks, the flat item texture otherwise), written as PNGs into
 * {@code <userfolder>/beamcraft/gui}. Pixel art is upscaled with nearest-neighbour so
 * BeamNG's linear filtering keeps it crisp.
 */
public final class GuiExport {
	private static final Logger LOG = LoggerFactory.getLogger("BeamCraft/GuiExport");
	private static final int ICON = 32;      // icon canvas before upscaling
	private static final int ICON_SCALE = 4; // -> 128px files

	private GuiExport() {}

	private static final String[][] SPRITES = {
		{"hotbar", "textures/gui/sprites/hud/hotbar.png"},
		{"hotbar_selection", "textures/gui/sprites/hud/hotbar_selection.png"},
		{"crosshair", "textures/gui/sprites/hud/crosshair.png"},
		{"heart_container", "textures/gui/sprites/hud/heart/container.png"},
		{"heart_full", "textures/gui/sprites/hud/heart/full.png"},
		{"heart_half", "textures/gui/sprites/hud/heart/half.png"},
		{"food_empty", "textures/gui/sprites/hud/food_empty.png"},
		{"food_half", "textures/gui/sprites/hud/food_half.png"},
		{"food_full", "textures/gui/sprites/hud/food_full.png"},
		{"xp_background", "textures/gui/sprites/hud/experience_bar_background.png"},
		{"xp_progress", "textures/gui/sprites/hud/experience_bar_progress.png"},
		{"font", "textures/font/ascii.png"},
	};

	/** HUD sprites + font metrics + skin. Returns a "gui" message for BeamNG. */
	public static JsonObject writeHud(Minecraft mc, Path dir, String version) throws IOException {
		ResourceManager rm = mc.getResourceManager();
		Path out = dir.resolve(version);
		Files.createDirectories(out);
		JsonObject msg = new JsonObject();
		msg.addProperty("t", "gui");
		msg.addProperty("dir", "/beamcraft/gui/" + version);
		JsonObject sizes = new JsonObject();
		for (String[] s : SPRITES) {
			BufferedImage img = read(rm, Identifier.withDefaultNamespace(s[1]));
			if (img == null) continue;
			JsonArray wh = new JsonArray();
			wh.add(img.getWidth());
			wh.add(img.getHeight());
			sizes.add(s[0], wh);
			int scale = s[0].equals("font") ? 4 : 8;
			write(upscale(img, scale), out.resolve(s[0] + ".png"));
			if (s[0].equals("font")) msg.add("glyphs", glyphWidths(img));
		}
		msg.add("sizes", sizes);

		// the player's skin (the default skin for the dev account)
		var skin = mc.getSkinManager().createLookup(mc.getGameProfile(), false).get();
		Identifier tex = skin.body().texturePath();
		BufferedImage skinImg = read(rm, tex);
		if (skinImg == null) skinImg = read(rm, Identifier.withDefaultNamespace("textures/entity/player/wide/steve.png"));
		if (skinImg != null) write(upscale(skinImg, 4), out.resolve("skin.png"));
		msg.addProperty("slim", skin.model().name().equalsIgnoreCase("slim"));
		return msg;
	}

	/** Advance width (in font pixels) of each of the 256 glyphs of ascii.png. */
	private static JsonArray glyphWidths(BufferedImage font) {
		int cell = font.getWidth() / 16;
		JsonArray w = new JsonArray();
		for (int c = 0; c < 256; c++) {
			int gx = (c % 16) * cell, gy = (c / 16) * cell;
			int last = -1;
			for (int x = cell - 1; x >= 0 && last < 0; x--) {
				for (int y = 0; y < cell; y++) {
					if ((font.getRGB(gx + x, gy + y) >>> 24) > 0) {
						last = x;
						break;
					}
				}
			}
			w.add(c == ' ' ? 4 : last < 0 ? 0 : last + 2);
		}
		return w;
	}

	// ------------------------------------------------------------------------------
	// item icons
	// ------------------------------------------------------------------------------

	public static Path iconPath(Path iconsDir, String itemId) {
		Identifier id = Identifier.parse(itemId);
		return iconsDir.resolve(id.getNamespace()).resolve(id.getPath() + ".png");
	}

	/** Write the icon for an item if it isn't on disk yet. Client thread. */
	public static void ensureIcon(Minecraft mc, Path iconsDir, String itemId) {
		Path file = iconPath(iconsDir, itemId);
		if (Files.exists(file)) return;
		try {
			Item item = BuiltInRegistries.ITEM.getValue(Identifier.parse(itemId));
			BufferedImage icon = renderIcon(mc, item, itemId);
			if (icon == null) return;
			Files.createDirectories(file.getParent());
			write(upscale(icon, ICON_SCALE), file);
		} catch (Exception e) {
			LOG.debug("No icon for {}: {}", itemId, e.toString());
		}
	}

	/** Icons for every item, for the picker. Background thread is fine for file IO only, so run on client thread in slices. */
	public static List<String> allItemIds() {
		List<String> ids = new ArrayList<>();
		for (Item item : BuiltInRegistries.ITEM) {
			String id = BuiltInRegistries.ITEM.getKey(item).toString();
			if (!id.equals("minecraft:air")) ids.add(id);
		}
		return ids;
	}

	private static BufferedImage renderIcon(Minecraft mc, Item item, String itemId) {
		ResourceManager rm = mc.getResourceManager();
		Identifier id = Identifier.parse(itemId);
		if (item instanceof BlockItem bi) {
			BlockState state = bi.getBlock().defaultBlockState();
			if (state.isSolidRender()) {
				BufferedImage cube = isometric(mc, state);
				if (cube != null) return cube;
			}
		}
		BufferedImage flat = read(rm, Identifier.fromNamespaceAndPath(id.getNamespace(), "textures/item/" + id.getPath() + ".png"));
		if (flat == null) flat = read(rm, Identifier.fromNamespaceAndPath(id.getNamespace(), "textures/block/" + id.getPath() + ".png"));
		if (flat == null && item instanceof BlockItem bi) {
			BufferedImage cube = isometric(mc, bi.getBlock().defaultBlockState());
			if (cube != null) return cube;
		}
		if (flat == null) return null;
		return fit(firstFrame(flat), ICON);
	}

	/** A Minecraft-inventory-style cube: top, left (north) and right (east) faces, shaded. */
	private static BufferedImage isometric(Minecraft mc, BlockState state) {
		BlockStateModel model = mc.getModelManager().getBlockStateModelSet().get(state);
		if (model == null) return null;
		List<BlockStateModelPart> parts = new ArrayList<>();
		model.collectParts(RandomSource.create(42L), parts);
		BufferedImage out = new BufferedImage(ICON, ICON, BufferedImage.TYPE_INT_ARGB);
		double s = ICON * 0.5;           // cube edge in screen px
		double cx = ICON / 2.0, cy = ICON / 2.0;
		double cos30 = Math.cos(Math.toRadians(30)) * s, sin30 = 0.5 * s;
		// screen-space parallelograms: origin, u edge, v edge (u,v in 0..1 texture space)
		// top: back corner at (cx, cy - s), going toward the viewer
		double[][] top = {{cx, cy - s}, {cos30, sin30}, {-cos30, sin30}};
		double[][] left = {{cx - cos30, cy - s + sin30}, {cos30, sin30}, {0, s}};
		double[][] right = {{cx, cy}, {cos30, -sin30}, {0, s}};
		boolean any = false;
		any |= drawFace(mc, state, parts, Direction.NORTH, left, 0.8f, out);
		any |= drawFace(mc, state, parts, Direction.EAST, right, 0.6f, out);
		any |= drawFace(mc, state, parts, Direction.UP, top, 1.0f, out);
		return any ? out : null;
	}

	private static boolean drawFace(Minecraft mc, BlockState state, List<BlockStateModelPart> parts, Direction dir,
		double[][] para, float shade, BufferedImage out) {
		boolean drew = false;
		for (BlockStateModelPart part : parts) {
			for (BakedQuad quad : part.getQuads(dir)) {
				TextureAtlasSprite sprite = quad.materialInfo().sprite();
				BufferedImage tex = read(mc.getResourceManager(), textureOf(sprite.contents().name()));
				if (tex == null) continue;
				tex = firstFrame(tex);
				int tint = -1;
				if (quad.materialInfo().isTinted()) {
					BlockTintSource src = mc.getBlockColors().getTintSource(state, quad.materialInfo().tintIndex());
					if (src != null) tint = src.color(state);
				}
				blitParallelogram(tex, para, shade, tint, out);
				drew = true;
			}
		}
		return drew;
	}

	private static void blitParallelogram(BufferedImage tex, double[][] p, float shade, int tint, BufferedImage out) {
		double ox = p[0][0], oy = p[0][1], ax = p[1][0], ay = p[1][1], bx = p[2][0], by = p[2][1];
		double det = ax * by - ay * bx;
		if (Math.abs(det) < 1e-9) return;
		for (int y = 0; y < out.getHeight(); y++) {
			for (int x = 0; x < out.getWidth(); x++) {
				double px = x + 0.5 - ox, py = y + 0.5 - oy;
				double u = (px * by - py * bx) / det;
				double v = (ax * py - ay * px) / det;
				if (u < 0 || u >= 1 || v < 0 || v >= 1) continue;
				int argb = tex.getRGB((int) (u * tex.getWidth()), (int) (v * tex.getHeight()));
				int a = argb >>> 24;
				if (a == 0) continue;
				int r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
				if (tint != -1) {
					r = r * ((tint >> 16) & 0xFF) / 255;
					g = g * ((tint >> 8) & 0xFF) / 255;
					b = b * (tint & 0xFF) / 255;
				}
				r = (int) (r * shade);
				g = (int) (g * shade);
				b = (int) (b * shade);
				if (a < 255) {
					int under = out.getRGB(x, y);
					float t = a / 255f;
					r = (int) (r * t + ((under >> 16) & 0xFF) * (1 - t));
					g = (int) (g * t + ((under >> 8) & 0xFF) * (1 - t));
					b = (int) (b * t + (under & 0xFF) * (1 - t));
					a = Math.max(a, under >>> 24);
				}
				out.setRGB(x, y, (a << 24) | (r << 16) | (g << 8) | b);
			}
		}
	}

	// ------------------------------------------------------------------------------
	// image helpers
	// ------------------------------------------------------------------------------

	static Identifier textureOf(Identifier sprite) {
		return Identifier.fromNamespaceAndPath(sprite.getNamespace(), "textures/" + sprite.getPath() + ".png");
	}

	static BufferedImage read(ResourceManager rm, Identifier file) {
		Optional<Resource> res = rm.getResource(file);
		if (res.isEmpty()) return null;
		try (InputStream in = res.get().open()) {
			BufferedImage img = ImageIO.read(in);
			if (img == null) return null;
			BufferedImage argb = new BufferedImage(img.getWidth(), img.getHeight(), BufferedImage.TYPE_INT_ARGB);
			argb.getGraphics().drawImage(img, 0, 0, null);
			return argb;
		} catch (IOException e) {
			return null;
		}
	}

	/** Animated textures are vertical strips of square frames. */
	static BufferedImage firstFrame(BufferedImage img) {
		if (img.getHeight() > img.getWidth() && img.getHeight() % img.getWidth() == 0) {
			return img.getSubimage(0, 0, img.getWidth(), img.getWidth());
		}
		return img;
	}

	private static BufferedImage fit(BufferedImage img, int size) {
		BufferedImage out = new BufferedImage(size, size, BufferedImage.TYPE_INT_ARGB);
		for (int y = 0; y < size; y++) {
			for (int x = 0; x < size; x++) out.setRGB(x, y, img.getRGB(x * img.getWidth() / size, y * img.getHeight() / size));
		}
		return out;
	}

	static BufferedImage upscale(BufferedImage img, int k) {
		BufferedImage out = new BufferedImage(img.getWidth() * k, img.getHeight() * k, BufferedImage.TYPE_INT_ARGB);
		for (int y = 0; y < out.getHeight(); y++) {
			for (int x = 0; x < out.getWidth(); x++) out.setRGB(x, y, img.getRGB(x / k, y / k));
		}
		return out;
	}

	static void write(BufferedImage img, Path file) throws IOException {
		Path tmp = file.resolveSibling(file.getFileName() + ".tmp");
		ImageIO.write(img, "png", tmp.toFile());
		Files.move(tmp, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
	}
}
