package dev.captience.beamcraft.client;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.awt.image.BufferedImage;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import javax.imageio.ImageIO;
import net.minecraft.client.Minecraft;
import net.minecraft.client.color.block.BlockColors;
import net.minecraft.client.color.block.BlockTintSource;
import net.minecraft.client.model.geom.builders.UVPair;
import net.minecraft.client.renderer.block.BlockStateModelSet;
import net.minecraft.client.renderer.block.dispatch.BlockStateModel;
import net.minecraft.client.renderer.block.dispatch.BlockStateModelPart;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.client.resources.model.geometry.BakedQuad;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.server.packs.resources.ResourceManager;
import net.minecraft.tags.BlockTags;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.item.DyeColor;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.SoundType;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.material.Fluids;
import org.joml.Vector3fc;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Turns Minecraft's baked block models into something BeamNG can draw.
 *
 * Every sprite any block state uses (with its tint baked in, since BeamNG has no
 * per-vertex tint) is packed into 4096px atlas pages written to BeamNG's userfolder.
 * Sprites are upscaled 7x with nearest-neighbour so linear filtering keeps the
 * pixel-art look, and each cell has an 8px gutter of extended edge pixels so
 * mipmapping doesn't bleed neighbours in.
 *
 * Per block state we export its quads: cull face, facing, render layer, atlas page,
 * four block-local positions and four page UVs. BeamNG meshes from those.
 */
public final class ModelExport {
	private static final Logger LOG = LoggerFactory.getLogger("BeamCraft/ModelExport");

	static final int PAGE = 4096;
	static final int CELL = 128;
	static final int PAD = 8;
	static final int CONTENT = CELL - 2 * PAD; // 112 = 16 * 7
	static final int PER_ROW = PAGE / CELL;
	static final int PER_PAGE = PER_ROW * PER_ROW;
	static final int FORMAT_VERSION = 1;

	static final int WATER_TINT = 0xFF3F76E4;

	private record TileSrc(Identifier sprite, int frameW, int frameH, int tint) {}

	private record Tile(int page, int col, int row) {}

	private final Map<String, Tile> tiles = new LinkedHashMap<>();
	private final Map<String, TileSrc> sources = new LinkedHashMap<>();
	private final Map<Integer, JsonObject> defCache = new HashMap<>();
	private String hash;
	private int pages;
	private final BlockStateModelSet models;
	private final BlockColors colors;

	private ModelExport(Minecraft mc) {
		this.models = mc.getModelManager().getBlockStateModelSet();
		this.colors = mc.getBlockColors();
	}

	public String hash() {
		return hash;
	}

	public int pages() {
		return pages;
	}

	public int tileCount() {
		return tiles.size();
	}

	/** Scan every block state for the sprites it uses. Client thread, after resources load. */
	public static ModelExport build(Minecraft mc) {
		ModelExport ex = new ModelExport(mc);
		ex.scan();
		return ex;
	}

	private static String tileKey(Identifier sprite, int tint) {
		return tint == -1 ? sprite.toString() : sprite + "#" + Integer.toHexString(tint);
	}

	private Tile tileFor(TextureAtlasSprite sprite, int tint) {
		Identifier name = sprite.contents().name();
		String key = tileKey(name, tint);
		Tile t = tiles.get(key);
		if (t == null) {
			int n = tiles.size();
			t = new Tile(n / PER_PAGE, n % PER_ROW, (n % PER_PAGE) / PER_ROW);
			tiles.put(key, t);
			sources.put(key, new TileSrc(name, sprite.contents().width(), sprite.contents().height(), tint));
		}
		return t;
	}

	private int tintOf(BlockState state, BakedQuad quad) {
		if (!quad.materialInfo().isTinted()) return -1;
		BlockTintSource src = colors.getTintSource(state, quad.materialInfo().tintIndex());
		if (src == null) return -1;
		int c = src.color(state);
		return c == -1 ? -1 : (c | 0xFF000000);
	}

	private List<BakedQuad> quadsOf(BlockState state) {
		List<BakedQuad> out = new ArrayList<>();
		BlockStateModel model = models.get(state);
		if (model == null) return out;
		List<BlockStateModelPart> parts = new ArrayList<>();
		model.collectParts(RandomSource.create(42L), parts);
		for (BlockStateModelPart part : parts) {
			for (Direction d : Direction.values()) out.addAll(part.getQuads(d));
			out.addAll(part.getQuads(null));
		}
		return out;
	}

	private void scan() {
		long t0 = System.nanoTime();
		for (BlockState state : Block.BLOCK_STATE_REGISTRY) {
			try {
				for (BakedQuad q : quadsOf(state)) tileFor(q.materialInfo().sprite(), tintOf(state, q));
			} catch (RuntimeException e) {
				LOG.debug("Skipping model of {}: {}", state, e.toString());
			}
			fluidSprites(state);
		}
		pages = (tiles.size() + PER_PAGE - 1) / PER_PAGE;
		StringBuilder sig = new StringBuilder("beamcraft-atlas-v").append(FORMAT_VERSION).append(';').append(CELL).append(';');
		for (Map.Entry<String, TileSrc> e : sources.entrySet()) {
			sig.append(e.getKey()).append(':').append(e.getValue().frameW).append('x').append(e.getValue().frameH).append(';');
		}
		hash = sha1(sig.toString()).substring(0, 12);
		LOG.info("Atlas scan: {} tile(s) on {} page(s), hash {} ({} ms)", tiles.size(), pages, hash, (System.nanoTime() - t0) / 1_000_000);
	}

	// Fluids have no block model; BeamNG gets a synthesized box from the still texture.
	private TextureAtlasSprite fluidSprite(FluidState fluid) {
		Minecraft mc = Minecraft.getInstance();
		Identifier id = isLava(fluid)
			? Identifier.withDefaultNamespace("block/lava_still")
			: Identifier.withDefaultNamespace("block/water_still");
		return mc.getAtlasManager().getAtlasOrThrow(net.minecraft.data.AtlasIds.BLOCKS).getSprite(id);
	}

	// fluid tags aren't bound until a world loads, so compare fluid types directly
	private static boolean isLava(FluidState fluid) {
		return fluid.getType().isSame(Fluids.LAVA);
	}

	private void fluidSprites(BlockState state) {
		FluidState fluid = state.getFluidState();
		if (fluid.isEmpty()) return;
		try {
			tileFor(fluidSprite(fluid), isLava(fluid) ? -1 : WATER_TINT);
		} catch (RuntimeException e) {
			LOG.debug("No fluid sprite for {}", state);
		}
	}

	// --------------------------------------------------------------------------------
	// per-state definitions
	// --------------------------------------------------------------------------------

	/** {"i":id,"o":opaque,"c":collides,"g":groundType,"q":[cull,dir,layer,page, 4x xyz, 4x uv, ...]} */
	public JsonObject stateDef(int id) {
		JsonObject cached = defCache.get(id);
		if (cached != null) return cached;
		BlockState state = Block.stateById(id);
		JsonObject o = new JsonObject();
		o.addProperty("i", id);
		boolean opaque = state.isSolidRender();
		boolean collides = !state.getCollisionShape(EmptyBlockGetter.INSTANCE, BlockPos.ZERO).isEmpty();
		o.addProperty("o", opaque ? 1 : 0);
		o.addProperty("c", collides ? 1 : 0);
		o.addProperty("g", groundType(state));
		o.addProperty("n", BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString());
		JsonArray q = new JsonArray();
		try {
			BlockStateModel model = models.get(state);
			if (model != null) {
				List<BlockStateModelPart> parts = new ArrayList<>();
				model.collectParts(RandomSource.create(42L), parts);
				for (BlockStateModelPart part : parts) {
					for (Direction d : Direction.values()) {
						for (BakedQuad quad : part.getQuads(d)) addQuad(q, state, quad, d.ordinal());
					}
					for (BakedQuad quad : part.getQuads(null)) addQuad(q, state, quad, -1);
				}
			}
			addFluid(q, state);
		} catch (RuntimeException e) {
			LOG.warn("Model export failed for {}", state, e);
		}
		o.add("q", q);
		defCache.put(id, o);
		return o;
	}

	private void addQuad(JsonArray out, BlockState state, BakedQuad quad, int cull) {
		TextureAtlasSprite sprite = quad.materialInfo().sprite();
		Tile tile = tiles.get(tileKey(sprite.contents().name(), tintOf(state, quad)));
		if (tile == null) return;
		out.add(cull);
		out.add(quad.direction().ordinal());
		out.add(quad.materialInfo().layer().ordinal());
		out.add(tile.page);
		for (int v = 0; v < 4; v++) {
			Vector3fc p = quad.position(v);
			out.add(round4(p.x()));
			out.add(round4(p.y()));
			out.add(round4(p.z()));
		}
		float du = sprite.getU1() - sprite.getU0();
		float dv = sprite.getV1() - sprite.getV0();
		for (int v = 0; v < 4; v++) {
			long uv = quad.packedUV(v);
			float lu = du == 0 ? 0 : (UVPair.unpackU(uv) - sprite.getU0()) / du;
			float lv = dv == 0 ? 0 : (UVPair.unpackV(uv) - sprite.getV0()) / dv;
			out.add(round6(pageU(tile, lu)));
			out.add(round6(pageV(tile, lv)));
		}
	}

	private static float pageU(Tile t, float local) {
		local = Math.max(0f, Math.min(1f, local));
		return (t.col * CELL + PAD + local * CONTENT) / PAGE;
	}

	private static float pageV(Tile t, float local) {
		local = Math.max(0f, Math.min(1f, local));
		return (t.row * CELL + PAD + local * CONTENT) / PAGE;
	}

	/** A box for the fluid, height from its level; top face always, sides culled by neighbours. */
	private void addFluid(JsonArray out, BlockState state) {
		FluidState fluid = state.getFluidState();
		if (fluid.isEmpty()) return;
		boolean water = !isLava(fluid);
		TextureAtlasSprite sprite = fluidSprite(fluid);
		Tile tile = tiles.get(tileKey(sprite.contents().name(), water ? WATER_TINT : -1));
		if (tile == null) return;
		float h = fluid.isSource() ? 14f / 16f : Math.max(0.1f, fluid.getAmount() / 9f);
		int layer = water ? 2 : 0;
		// face: cull, dir, 4 corners CCW from outside (MC convention)
		float[][][] faces = {
			{{0, h, 0}, {0, h, 1}, {1, h, 1}, {1, h, 0}},   // up (1)
			{{0, 0, 1}, {0, 0, 0}, {1, 0, 0}, {1, 0, 1}},   // down (0)
			{{1, h, 0}, {1, 0, 0}, {0, 0, 0}, {0, h, 0}},   // north (2)
			{{0, h, 1}, {0, 0, 1}, {1, 0, 1}, {1, h, 1}},   // south (3)
			{{0, h, 0}, {0, 0, 0}, {0, 0, 1}, {0, h, 1}},   // west (4)
			{{1, h, 1}, {1, 0, 1}, {1, 0, 0}, {1, h, 0}},   // east (5)
		};
		int[] dirs = {1, 0, 2, 3, 4, 5};
		float[][] uv = {{0, 0}, {0, 1}, {1, 1}, {1, 0}};
		for (int f = 0; f < faces.length; f++) {
			int dir = dirs[f];
			out.add(dir == 1 && h < 1f ? -1 : dir);
			out.add(dir);
			out.add(layer);
			out.add(tile.page);
			for (float[] p : faces[f]) {
				out.add(p[0]);
				out.add(p[1]);
				out.add(p[2]);
			}
			for (float[] t : uv) {
				out.add(round6(pageU(tile, t[0])));
				out.add(round6(pageV(tile, t[1])));
			}
		}
	}

	private static float round4(float f) {
		return Math.round(f * 10000f) / 10000f;
	}

	private static float round6(float f) {
		return Math.round(f * 1000000f) / 1000000f;
	}

	/** BeamNG ground model for tyre grip, sounds and particles. */
	static String groundType(BlockState state) {
		Block b = state.getBlock();
		if (state.is(BlockTags.ICE)) return "ICE";
		if (b == Blocks.SLIME_BLOCK) return "SLIPPERY";
		if (b == Blocks.HONEY_BLOCK || b == Blocks.MUD || b == Blocks.SOUL_SOIL || b == Blocks.SOUL_SAND) return "MUD";
		if (b == Blocks.DIRT || b == Blocks.COARSE_DIRT || b == Blocks.PODZOL || b == Blocks.ROOTED_DIRT
			|| b == Blocks.DIRT_PATH || b == Blocks.FARMLAND || b == Blocks.MYCELIUM) return "DIRT";
		if (b == Blocks.COBBLESTONE || b == Blocks.MOSSY_COBBLESTONE || b == Blocks.COBBLED_DEEPSLATE) return "COBBLESTONE";
		if (b == Blocks.SNOW_BLOCK || b == Blocks.POWDER_SNOW) return "SNOWBANK";
		if (state.is(BlockTags.LEAVES)) return "LEAVES_THIN";
		if (b == Blocks.CONCRETE.pick(DyeColor.BLACK) || b == Blocks.CONCRETE.pick(DyeColor.GRAY)) return "ASPHALT";
		SoundType s = state.getSoundType();
		if (s == SoundType.GRASS) return "GRASS";
		if (s == SoundType.GRAVEL) return "GRAVEL";
		if (s == SoundType.SAND) return "SAND";
		if (s == SoundType.SNOW) return "SNOW";
		if (s == SoundType.WOOD || s == SoundType.NETHER_WOOD || s == SoundType.BAMBOO_WOOD || s == SoundType.CHERRY_WOOD) return "WOOD";
		if (s == SoundType.METAL || s == SoundType.ANVIL || s == SoundType.COPPER || s == SoundType.CHAIN) return "METAL";
		if (s == SoundType.WOOL) return "PLASTIC";
		if (s == SoundType.MUD || s == SoundType.ROOTED_DIRT) return "MUD";
		return "ROCK";
	}

	// --------------------------------------------------------------------------------
	// atlas pages
	// --------------------------------------------------------------------------------

	/** Write any missing pages into dir (BeamNG userfolder/beamcraft/atlas). Safe off-thread. */
	public void writePages(ResourceManager resources, Path dir) throws IOException {
		Files.createDirectories(dir);
		boolean allPresent = true;
		for (int p = 0; p < pages; p++) {
			if (!Files.exists(dir.resolve(hash + "_" + p + ".png"))) allPresent = false;
		}
		if (allPresent) {
			LOG.info("Atlas {} already on disk", hash);
			return;
		}
		long t0 = System.nanoTime();
		BufferedImage[] images = new BufferedImage[pages];
		for (int p = 0; p < pages; p++) images[p] = new BufferedImage(PAGE, PAGE, BufferedImage.TYPE_INT_ARGB);
		Map<Identifier, BufferedImage> cache = new HashMap<>();
		for (Map.Entry<String, Tile> e : tiles.entrySet()) {
			TileSrc src = sources.get(e.getKey());
			Tile t = e.getValue();
			BufferedImage img = cache.computeIfAbsent(src.sprite, id -> loadSprite(resources, id));
			blitTile(images[t.page], t, img, src);
		}
		for (int p = 0; p < pages; p++) {
			Path tmp = dir.resolve(hash + "_" + p + ".png.tmp");
			ImageIO.write(images[p], "png", tmp.toFile());
			Files.move(tmp, dir.resolve(hash + "_" + p + ".png"), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
		}
		Files.writeString(dir.resolve(hash + ".txt"), String.join("\n", tiles.keySet()), StandardCharsets.UTF_8);
		LOG.info("Wrote {} atlas page(s) to {} in {} ms", pages, dir, (System.nanoTime() - t0) / 1_000_000);
	}

	private static BufferedImage loadSprite(ResourceManager resources, Identifier sprite) {
		Identifier file = Identifier.fromNamespaceAndPath(sprite.getNamespace(), "textures/" + sprite.getPath() + ".png");
		Optional<Resource> res = resources.getResource(file);
		if (res.isPresent()) {
			try (InputStream in = res.get().open()) {
				BufferedImage img = ImageIO.read(in);
				if (img != null) return img;
			} catch (IOException e) {
				LOG.debug("Unreadable sprite {}", file);
			}
		}
		// missing texture: the classic magenta/black checker
		BufferedImage img = new BufferedImage(16, 16, BufferedImage.TYPE_INT_ARGB);
		for (int y = 0; y < 16; y++) {
			for (int x = 0; x < 16; x++) img.setRGB(x, y, ((x < 8) ^ (y < 8)) ? 0xFFF800F8 : 0xFF000000);
		}
		return img;
	}

	private static void blitTile(BufferedImage page, Tile t, BufferedImage src, TileSrc info) {
		int fw = Math.min(info.frameW > 0 ? info.frameW : src.getWidth(), src.getWidth());
		int fh = Math.min(info.frameH > 0 ? info.frameH : src.getWidth(), src.getHeight());
		int x0 = t.col * CELL, y0 = t.row * CELL;
		int tint = info.tint;
		for (int dy = -PAD; dy < CONTENT + PAD; dy++) {
			int cy = Math.max(0, Math.min(CONTENT - 1, dy));
			int sy = cy * fh / CONTENT;
			for (int dx = -PAD; dx < CONTENT + PAD; dx++) {
				int cx = Math.max(0, Math.min(CONTENT - 1, dx));
				int sx = cx * fw / CONTENT;
				int argb = src.getRGB(sx, sy);
				if (tint != -1) argb = multiply(argb, tint);
				page.setRGB(x0 + PAD + dx, y0 + PAD + dy, argb);
			}
		}
	}

	private static int multiply(int argb, int tint) {
		int a = argb >>> 24;
		int r = ((argb >> 16) & 0xFF) * ((tint >> 16) & 0xFF) / 255;
		int g = ((argb >> 8) & 0xFF) * ((tint >> 8) & 0xFF) / 255;
		int b = (argb & 0xFF) * (tint & 0xFF) / 255;
		return (a << 24) | (r << 16) | (g << 8) | b;
	}

	private static String sha1(String s) {
		try {
			return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-1").digest(s.getBytes(StandardCharsets.UTF_8)));
		} catch (NoSuchAlgorithmException e) {
			return Integer.toHexString(s.hashCode());
		}
	}
}
