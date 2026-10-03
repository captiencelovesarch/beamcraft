package dev.captience.beamcraft.client;
import java.awt.image.BufferedImage;
import java.nio.file.*;
import java.util.*;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.resources.Identifier;

/** Shared sprite colour/opacity files, preserving source texels and alpha. */
final class RenderAssets {
    record Texture(String color, String mask) {}
    private static final Map<String, Texture> cache = new HashMap<>();
    static Texture sprite(Minecraft mc, Path root, TextureAtlasSprite sprite, int tint) throws Exception {
        Identifier id = sprite.contents().name();
        String key = root + "/" + id + "/" + tint;
        Texture found = cache.get(key); if (found != null) return found;
        BufferedImage src = GuiExport.read(mc.getResourceManager(), Identifier.fromNamespaceAndPath(id.getNamespace(), "textures/" + id.getPath() + ".png"));
        if (src == null) src = GuiExport.read(mc.getResourceManager(), Identifier.fromNamespaceAndPath(id.getNamespace(), "textures/particle/" + id.getPath() + ".png"));
        if (src == null) return null;
        return write(root, id, src, Math.min(src.getWidth(), sprite.contents().width()), Math.min(src.getHeight(), sprite.contents().height()), tint, key);
    }
    static Texture file(Minecraft mc, Path root, Identifier id, int tint) throws Exception {
        String key=root+"/file/"+id+"/"+tint; Texture found=cache.get(key);if(found!=null)return found;
        BufferedImage src=GuiExport.read(mc.getResourceManager(),id);if(src==null)return null;
        return write(root,id,src,src.getWidth(),src.getHeight(),tint,key);
    }
    private static Texture write(Path root, Identifier id, BufferedImage src, int w, int h, int tint, String key) throws Exception {
        BufferedImage image = new BufferedImage(w,h,BufferedImage.TYPE_INT_ARGB), mask = new BufferedImage(w,h,BufferedImage.TYPE_INT_ARGB);
        for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
            int c = src.getRGB(x,y), a = c >>> 24;
            if(tint != -1) c = (a<<24) | (((c>>16 & 255)*(tint>>16 &255)/255)<<16) | (((c>>8 &255)*(tint>>8 &255)/255)<<8) | ((c&255)*(tint&255)/255);
            image.setRGB(x,y,c); mask.setRGB(x,y,0xff000000 | (a<<16) | (a<<8) | a);
        }
        String name = id.getNamespace()+"/"+id.getPath()+"_"+Integer.toHexString(tint);
        Path file = root.resolve(name+".color.png"), opacity = root.resolve(name+"_opacity.data.png");
        Files.createDirectories(file.getParent());
        GuiExport.write(GuiExport.upscale(image,8), file); GuiExport.write(GuiExport.upscale(mask,8), opacity);
        String url = "/beamcraft/render/"+name;
        Texture result = new Texture(url+".color.png",url+"_opacity.data.png"); cache.put(key,result); return result;
    }
}
