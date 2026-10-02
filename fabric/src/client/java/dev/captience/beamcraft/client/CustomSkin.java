package dev.captience.beamcraft.client;

import com.mojang.blaze3d.platform.NativeImage;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.texture.DynamicTexture;
import net.minecraft.core.ClientAsset;
import net.minecraft.resources.Identifier;
import net.minecraft.world.entity.player.PlayerModelType;
import net.minecraft.world.entity.player.PlayerSkin;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Your own skin on the hidden client (which plays offline, so it would otherwise get a
 * default one): <game dir>/beamcraft/skin.png, wide or slim arms detected from the
 * pixels. Used for the first-person arm, F5 views and the model BeamNG draws.
 */
public final class CustomSkin {
	private static final Logger LOG = LoggerFactory.getLogger("BeamCraft/Skin");
	public static final Identifier TEXTURE = Identifier.fromNamespaceAndPath("beamcraft", "skin/custom");

	private static @Nullable PlayerSkin skin;
	private static @Nullable Path file;

	private CustomSkin() {}

	public static @Nullable PlayerSkin get() {
		return skin;
	}

	public static @Nullable Path file() {
		return file;
	}

	public static void load(Minecraft mc) {
		Path path = mc.gameDirectory.toPath().resolve("beamcraft").resolve("skin.png");
		if (!Files.isRegularFile(path)) return;
		try (InputStream in = Files.newInputStream(path)) {
			NativeImage image = NativeImage.read(in);
			if (image.getWidth() != 64 || (image.getHeight() != 64 && image.getHeight() != 32)) {
				LOG.warn("Skin {} is {}x{}, expected 64x64", path, image.getWidth(), image.getHeight());
				image.close();
				return;
			}
			// slim (Alex) arms leave the right arm's outer column transparent
			boolean slim = image.getHeight() == 64 && ((image.getPixel(54, 20) >>> 24) & 0xFF) == 0;
			mc.getTextureManager().register(TEXTURE, new DynamicTexture(() -> "BeamCraft skin", image));
			skin = PlayerSkin.insecure(new ClientAsset.ResourceTexture(TEXTURE, TEXTURE), null, null,
				slim ? PlayerModelType.SLIM : PlayerModelType.WIDE);
			file = path;
			LOG.info("Using custom skin {} ({} arms)", path, slim ? "slim" : "wide");
		} catch (Exception e) {
			LOG.warn("Could not load skin {}", path, e);
		}
	}
}
