package dev.captience.beamcraft.client;
import com.google.gson.*;
import com.mojang.blaze3d.vertex.PoseStack;
import dev.captience.beamcraft.Bridge;
import dev.captience.beamcraft.client.mixin.*;
import java.nio.file.Path;
import java.util.*;
import net.minecraft.client.Minecraft;
import net.minecraft.client.model.geom.builders.UVPair;
import net.minecraft.client.renderer.item.ItemStackRenderState;
import net.minecraft.world.entity.*;
import net.minecraft.world.item.*;
import org.joml.Vector3f;
import org.joml.Quaternionf;

/** Exports the resolved vanilla item model, including its display transforms and tints. */
final class ItemExport {
    private static final Set<String> sent = new HashSet<>();
    static void reset() { sent.clear(); }
    static String model(Minecraft mc, Path root, ItemStack stack, Entity owner, ItemDisplayContext context) {
        if (stack.isEmpty() || root == null) return null;
        try {
            ItemStackRenderState state = new ItemStackRenderState();
            if(owner instanceof LivingEntity living) mc.getItemModelResolver().updateForLiving(state,stack,context,living);
            else mc.getItemModelResolver().updateForNonLiving(state,stack,context,owner);
            JsonArray quads = new JsonArray();
            ItemStateAccessor access = (ItemStateAccessor)state;
            boolean hand = context == ItemDisplayContext.THIRD_PERSON_RIGHT_HAND || context == ItemDisplayContext.THIRD_PERSON_LEFT_HAND;
            for (int i=0;i<access.beamcraft$count();i++) {
                var layer = access.beamcraft$layers()[i]; PoseStack pose = new PoseStack();
                if(hand) { pose.mulPose(new Quaternionf().rotationX((float)-Math.PI/2)); pose.mulPose(new Quaternionf().rotationY((float)Math.PI)); pose.translate((context.leftHand()?-1:1)/16f,2/16f,-10/16f); }
                if (layer.prepareQuadList().isEmpty()) {
                    special(mc, root, layer, pose, hand, quads);
                    continue;
                }
                ((ItemLayerAccessor)layer).beamcraft$transform(pose.last());
                for(var quad : layer.prepareQuadList()) {
                    var sp = quad.materialInfo().sprite(); int tint = -1;
                    if(quad.materialInfo().isTinted() && layer.tintLayers()!=null && quad.materialInfo().tintIndex()<layer.tintLayers().size()) tint=layer.tintLayers().getInt(quad.materialInfo().tintIndex());
                    var tex = RenderAssets.sprite(mc,root,sp,tint); if(tex==null) continue;
                    JsonObject q = new JsonObject(); q.addProperty("tex",tex.color()); q.addProperty("mask",tex.mask()); JsonArray p=new JsonArray(),uv=new JsonArray();
                    for(int v=0;v<4;v++) {
                        Vector3f pos=new Vector3f(quad.position(v)); pose.last().pose().transformPosition(pos);
                        p.add(hand?-pos.x():pos.x()); p.add(-pos.z()); p.add(hand?-pos.y():pos.y());
                        long packed=quad.packedUV(v); uv.add((UVPair.unpackU(packed)-sp.getU0())/(sp.getU1()-sp.getU0())); uv.add((UVPair.unpackV(packed)-sp.getV0())/(sp.getV1()-sp.getV0()));
                    }
                    q.add("p",p); q.add("uv",uv); quads.add(q);
                }
            }
            if(quads.isEmpty()) return null;
            String id = UUID.nameUUIDFromBytes(quads.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)).toString();
            if(sent.add(id)) {JsonObject m=new JsonObject();m.addProperty("t","itemModel");m.addProperty("id",id);m.add("q",quads);Bridge.send(m);}
            return id;
        } catch(Exception e) { dev.captience.beamcraft.BeamCraft.LOG.warn("Item export failed: {}",e.toString()); return null; }
    }
    @SuppressWarnings({"rawtypes", "unchecked"})
    private static void special(Minecraft mc, Path root, ItemStackRenderState.LayerRenderState layer, PoseStack pose, boolean hand, JsonArray out) throws Exception {
        // Capture the same ModelPart submissions used by shield, trident, chest,
        // skull and other special item renderers; do not substitute flat icons.
        var collector = (net.minecraft.client.renderer.SubmitNodeCollector)java.lang.reflect.Proxy.newProxyInstance(
            ItemExport.class.getClassLoader(), new Class[]{net.minecraft.client.renderer.SubmitNodeCollector.class}, (proxy, method, args) -> {
                if(method.getName().equals("order")) return proxy;
                if(method.isDefault()) return java.lang.reflect.InvocationHandler.invokeDefault(proxy, method, args);
                if(method.getName().equals("submitModel")) {
                    var model=(net.minecraft.client.model.Model)args[0]; model.setupAnim(args[1]);
                    var sprite=(net.minecraft.client.renderer.texture.TextureAtlasSprite)args[7];
                    RenderAssets.Texture texture;
                    if(sprite != null) texture=RenderAssets.sprite(mc,root,sprite,(Integer)args[6]);
                    else {
                        var setup=((RenderTypeAccessor)args[3]).beamcraft$state();
                        var binding=((RenderSetupAccessor)(Object)setup).beamcraft$textures().get("Sampler0");
                        texture=binding==null?null:RenderAssets.file(mc,root,((TextureBindingAccessor)binding).beamcraft$location(),(Integer)args[6]);
                    }
                    {
                        if(texture != null) model.root().visit((PoseStack)args[2], (partPose,path,index,cube) -> {
                            for(var polygon:cube.polygons) {
                                JsonObject q=new JsonObject();q.addProperty("tex",texture.color());q.addProperty("mask",texture.mask());JsonArray p=new JsonArray(),uv=new JsonArray();
                                for(var v:polygon.vertices()) {
                                    var point=new Vector3f(v.worldX(),v.worldY(),v.worldZ());partPose.pose().transformPosition(point);
                                    p.add(hand?-point.x():point.x());p.add(-point.z());p.add(hand?-point.y():point.y());uv.add(v.u());uv.add(v.v());
                                }
                                q.add("p",p);q.add("uv",uv);out.add(q);
                            }
                        });
                    }
                }
                return null;
            });
        ((ItemLayerAccessor)layer).beamcraft$submit(pose,collector,15728880,0,0);
    }

}
