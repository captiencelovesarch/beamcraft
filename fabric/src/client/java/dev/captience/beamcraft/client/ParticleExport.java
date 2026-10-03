package dev.captience.beamcraft.client;
import com.google.gson.*;
import dev.captience.beamcraft.Bridge;
import dev.captience.beamcraft.client.mixin.*;
import java.nio.file.Path;
import net.minecraft.client.Minecraft;
import net.minecraft.client.particle.SingleQuadParticle;

/** Vanilla owns emission, collision, colours, sprite frames, size and lifetime. */
final class ParticleExport {
    private static boolean hadParticles;
    private static Path warmed;

    /**
     * Every particle sprite, exported up front and listed to BeamNG: it converts a
     * texture to DDS the first time a material uses it and shows a placeholder until
     * that's done - short-lived particles (explosions) used to be gone by then.
     */
    static void resetWarm() { warmed = null; }

    static void warmUp(Minecraft mc, Path root) {
        if (root == null || root.equals(warmed)) return;
        var tex = mc.getTextureManager().getTexture(net.minecraft.client.renderer.texture.TextureAtlas.LOCATION_PARTICLES);
        if (!(tex instanceof net.minecraft.client.renderer.texture.TextureAtlas atlas)) return;
        warmed = root;
        JsonArray list = new JsonArray();
        for (var sprite : ((TextureAtlasAccess) atlas).beamcraft$sprites()) {
            try {
                var t = RenderAssets.sprite(mc, root, sprite, -1);
                if (t == null) continue;
                JsonArray pair = new JsonArray(); pair.add(t.color()); pair.add(t.mask()); list.add(pair);
            } catch (Exception ignored) {}
        }
        JsonObject m = new JsonObject(); m.addProperty("t", "warm"); m.add("l", list); Bridge.send(m);
    }
    static void send(Minecraft mc, Path root) {
        if(mc.level==null || mc.player==null || root==null) return;
        JsonArray list=new JsonArray();
        for(var group : ((ParticleEngineAccessor)mc.particleEngine).beamcraft$groups().values()) {
            for(var p : ((ParticleGroupAccessor)group).beamcraft$particles()) {
                if(!(p instanceof SingleQuadParticle quad) || !p.isAlive() || list.size()>=384) continue;
                var bounds=p.getBoundingBox(); var center=bounds.getCenter();
                if(mc.player.distanceToSqr(center)>4096) continue;
                var a=(QuadParticleAccessor)quad; var sprite=a.beamcraft$sprite(); if(sprite==null) continue;
                try {
                    var tex=RenderAssets.sprite(mc,root,sprite,-1); if(tex==null) continue;
                    JsonObject o=new JsonObject(); o.addProperty("id",System.identityHashCode(p));
                    o.addProperty("x",center.x);o.addProperty("y",bounds.minY);o.addProperty("z",center.z);
                    o.addProperty("s",quad.getQuadSize(1));o.addProperty("roll",a.beamcraft$roll());
                    o.addProperty("r",a.beamcraft$r());o.addProperty("g",a.beamcraft$g());o.addProperty("b",a.beamcraft$b());o.addProperty("a",a.beamcraft$alpha());
                    o.addProperty("tex",tex.color());o.addProperty("mask",tex.mask());
                    float du=sprite.getU1()-sprite.getU0(),dv=sprite.getV1()-sprite.getV0();
                    JsonArray uv=new JsonArray();uv.add((a.beamcraft$u0()-sprite.getU0())/du);uv.add((a.beamcraft$v0()-sprite.getV0())/dv);
                    uv.add((a.beamcraft$u1()-sprite.getU0())/du);uv.add((a.beamcraft$v1()-sprite.getV0())/dv);o.add("uv",uv);list.add(o);
                } catch(Exception ignored) {}
            }
        }
        if(list.isEmpty()&&!hadParticles) return;
        hadParticles=!list.isEmpty();JsonObject m=new JsonObject();m.addProperty("t","particles");m.add("l",list);Bridge.send(m);
    }
}
