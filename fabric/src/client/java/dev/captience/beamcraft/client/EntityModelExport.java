package dev.captience.beamcraft.client;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import com.mojang.blaze3d.vertex.PoseStack;
import dev.captience.beamcraft.Bridge;
import dev.captience.beamcraft.client.mixin.AgeableMobRendererAccess;
import dev.captience.beamcraft.client.mixin.LivingEntityRendererAccess;
import dev.captience.beamcraft.client.mixin.ModelPartAccess;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import net.minecraft.client.Minecraft;
import net.minecraft.client.model.EntityModel;
import net.minecraft.client.model.geom.ModelPart;
import net.minecraft.client.renderer.entity.AgeableMobRenderer;
import net.minecraft.client.renderer.entity.EntityRenderer;
import net.minecraft.client.renderer.entity.LivingEntityRenderer;
import net.minecraft.client.renderer.entity.state.LivingEntityRenderState;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.entity.LivingEntity;
import org.joml.Matrix4f;
import org.joml.Quaternionf;
import org.joml.Vector3f;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Mobs as Minecraft draws them. For every living entity we run its real renderer's
 * setup (render state, setupAnim, setupRotations, scale) and walk the model's
 * ModelPart tree exactly like ModelPart.render does, recording each part's final
 * matrix relative to the entity's feet. BeamNG gets each model's geometry once
 * ("mobModel": per part, quads in part-local blocks with UVs) and then 20 times a
 * second a list of part transforms per entity, so walking, attacking, death tilts,
 * baby sizes and so on all come out of vanilla's own animation code.
 *
 * Only the base model layer is exported (no armour/emissive layers yet).
 */
final class EntityModelExport {
	private static final Logger LOG = LoggerFactory.getLogger("BeamCraft/Mobs");

	/** Exported model: parts with cubes, in traversal order. */
	private record Model(String key, IdentityHashMap<ModelPart, Integer> index) {}

	private static final Map<ModelPart, Model> MODELS = new IdentityHashMap<>();
	private static final Map<String, RenderAssets.Texture> TEXTURES = new HashMap<>();
	private static int modelCounter;

	private EntityModelExport() {}

	/** BeamNG reconnected: it has forgotten every model. */
	static void reset() {
		MODELS.clear();
	}

	/**
	 * Pose one entity: run its renderer's real submit() into a recording collector, so
	 * every model it draws comes along - the body plus layers like sheep wool, armour,
	 * saddles, spider eyes - each with its own texture and tint, posed by vanilla.
	 * Returns {"L":[{"k":model,"tx":texture,"mk":mask,"p":[...]},...]} or null.
	 */
	@SuppressWarnings({"unchecked", "rawtypes"})
	static String pose(Minecraft mc, Path renderRoot, net.minecraft.world.entity.Entity e) {
		if (renderRoot == null) return null;
		try {
			EntityRenderer renderer = mc.getEntityRenderDispatcher().getRenderer(e);
			if (renderer == null) return null;
			var state = renderer.createRenderState(e, 1f);
			String type = BuiltInRegistries.ENTITY_TYPE.getKey(e.getType()).getPath();
			StringBuilder sb = new StringBuilder(512).append("{\"L\":[");
			int[] layers = {0};
			var collector = (net.minecraft.client.renderer.SubmitNodeCollector) java.lang.reflect.Proxy.newProxyInstance(
				EntityModelExport.class.getClassLoader(), new Class[] {net.minecraft.client.renderer.SubmitNodeCollector.class},
				(proxy, method, args) -> {
					String name = method.getName();
					if (name.equals("order")) return proxy;
					if (name.equals("submitModel") && args.length == 10) {
						layer(mc, renderRoot, type, (net.minecraft.client.model.Model) args[0], args[1], (PoseStack) args[2],
							(net.minecraft.client.renderer.rendertype.RenderType) args[3], (Integer) args[6],
							(net.minecraft.client.renderer.texture.TextureAtlasSprite) args[7], sb, layers);
						return null;
					}
					if (method.isDefault()) return java.lang.reflect.InvocationHandler.invokeDefault(proxy, method, args);
					return null; // shadows, name tags, items, flames...: not exported
				});
			renderer.submit(state, new PoseStack(), collector, new net.minecraft.client.renderer.state.level.CameraRenderState());
			if (layers[0] == 0) return null;
			return sb.append("]}").toString();
		} catch (Throwable ex) {
			LOG.debug("No model for {}", e.getType(), ex);
			return null;
		}
	}

	@SuppressWarnings({"unchecked", "rawtypes"})
	private static void layer(Minecraft mc, Path root, String type, net.minecraft.client.model.Model model, Object state,
			PoseStack ps, net.minecraft.client.renderer.rendertype.RenderType renderType, int tint,
			net.minecraft.client.renderer.texture.TextureAtlasSprite sprite, StringBuilder sb, int[] layers) throws Exception {
		RenderAssets.Texture tex;
		int rgb = (tint & 0xFF000000) == 0 ? -1 : (tint | 0xFF000000) == -1 ? -1 : tint & 0xFFFFFF;
		if (sprite != null) {
			tex = RenderAssets.sprite(mc, root, sprite, rgb);
		} else {
			var setup = ((dev.captience.beamcraft.client.mixin.RenderTypeAccessor) renderType).beamcraft$state();
			var binding = ((dev.captience.beamcraft.client.mixin.RenderSetupAccessor) (Object) setup).beamcraft$textures().get("Sampler0");
			if (binding == null) return;
			Identifier id = ((dev.captience.beamcraft.client.mixin.TextureBindingAccessor) binding).beamcraft$location();
			String key = id + "/" + rgb;
			tex = TEXTURES.get(key);
			if (tex == null) {
				tex = RenderAssets.file(mc, root, id, rgb);
				if (tex == null) return;
				TEXTURES.put(key, tex);
			}
		}
		if (tex == null) return;
		// Model.Simple wrappers are made per call: identify geometry by the root part
		ModelPart rootPart = model.root();
		Model exported = MODELS.get(rootPart);
		if (exported == null) {
			exported = export(rootPart, type);
			MODELS.put(rootPart, exported);
		}
		model.setupAnim(state);
		if (layers[0]++ > 0) sb.append(',');
		sb.append("{\"k\":\"").append(exported.key).append("\",\"tx\":\"").append(tex.color())
			.append("\",\"mk\":\"").append(tex.mask()).append("\",\"p\":[");
		ps.pushPose();
		walk(rootPart, ps, exported.index, sb, new int[] {0}, new Quaternionf(), new Vector3f(), new Vector3f());
		ps.popPose();
		sb.append("]}");
	}

	private static void walk(ModelPart part, PoseStack ps, IdentityHashMap<ModelPart, Integer> index, StringBuilder sb,
			int[] count, Quaternionf q, Vector3f t, Vector3f s) {
		if (!part.visible) return;
		ModelPartAccess pa = (ModelPartAccess) (Object) part;
		ps.pushPose();
		part.translateAndRotate(ps);
		Integer idx = index.get(part);
		if (idx != null && !part.skipDraw) {
			Matrix4f m = ps.last().pose();
			m.getTranslation(t);
			m.getNormalizedRotation(q);
			m.getScale(s);
			if (count[0]++ > 0) sb.append(',');
			sb.append(idx).append(',').append(r(t.x)).append(',').append(r(t.y)).append(',').append(r(t.z)).append(',')
				.append(r(q.x)).append(',').append(r(q.y)).append(',').append(r(q.z)).append(',').append(r(q.w)).append(',')
				.append(r((s.x + s.y + s.z) / 3f));
		}
		for (ModelPart child : pa.beamcraft$children().values()) walk(child, ps, index, sb, count, q, t, s);
		ps.popPose();
	}

	private static String r(float v) {
		return Float.toString(Math.round(v * 10000f) / 10000f);
	}

	/** Send a model's geometry: every part with cubes, quads in part-local blocks. */
	private static Model export(ModelPart root, String typeName) {
		String key = typeName + "_" + (modelCounter++);
		IdentityHashMap<ModelPart, Integer> index = new IdentityHashMap<>();
		List<ModelPart> parts = new ArrayList<>();
		collect(root, index, parts);
		JsonObject msg = new JsonObject();
		msg.addProperty("t", "mobModel");
		msg.addProperty("k", key);
		JsonArray list = new JsonArray();
		for (ModelPart part : parts) {
			JsonArray quads = new JsonArray();
			for (ModelPart.Cube cube : ((ModelPartAccess) (Object) part).beamcraft$cubes()) {
				for (ModelPart.Polygon poly : cube.polygons) {
					// x,y,z,u,v for 4 vertices, then the normal
					for (ModelPart.Vertex v : poly.vertices()) {
						quads.add(rr(v.worldX())); quads.add(rr(v.worldY())); quads.add(rr(v.worldZ()));
						quads.add(rr(v.u())); quads.add(rr(v.v()));
					}
					quads.add(rr(poly.normal().x())); quads.add(rr(poly.normal().y())); quads.add(rr(poly.normal().z()));
				}
			}
			list.add(quads);
		}
		msg.add("parts", list);
		Bridge.send(msg);
		LOG.info("Exported model {} ({} parts)", key, parts.size());
		return new Model(key, index);
	}

	private static double rr(float v) {
		return Math.round(v * 100000.0) / 100000.0;
	}

	private static void collect(ModelPart part, IdentityHashMap<ModelPart, Integer> index, List<ModelPart> parts) {
		ModelPartAccess pa = (ModelPartAccess) (Object) part;
		if (!pa.beamcraft$cubes().isEmpty()) {
			index.put(part, parts.size());
			parts.add(part);
		}
		for (ModelPart child : pa.beamcraft$children().values()) collect(child, index, parts);
	}

	/**
	 * The player's body tilt (elytra flight, swimming, riptide, death) as the rotation
	 * LivingEntityRenderer.setupRotations applies on top of the plain body yaw, in the
	 * yawed body frame (MC axes): {qx,qy,qz,qw, tx,ty,tz}. Null when upright.
	 */
	@SuppressWarnings({"unchecked", "rawtypes"})
	static float[] bodyTilt(Minecraft mc, LivingEntity e) {
		EntityRenderer<?, ?> any = mc.getEntityRenderDispatcher().getRenderer(e);
		if (!(any instanceof LivingEntityRenderer renderer)) return null;
		LivingEntityRenderState state = (LivingEntityRenderState) renderer.createRenderState(e, 1f);
		PoseStack ps = new PoseStack();
		// undo the plain yaw so only the extra tilt is left
		ps.mulPose(new Quaternionf().rotationY((float) Math.toRadians(-(180f - state.bodyRot))));
		((LivingEntityRendererAccess) renderer).beamcraft$setupRotations(state, ps, state.bodyRot, state.scale);
		Matrix4f m = ps.last().pose();
		Quaternionf q = m.getNormalizedRotation(new Quaternionf());
		Vector3f t = m.getTranslation(new Vector3f());
		if (Math.abs(q.w) > 0.99999f && t.lengthSquared() < 1e-8f) return null;
		return new float[] {q.x, q.y, q.z, q.w, t.x, t.y, t.z};
	}
}
