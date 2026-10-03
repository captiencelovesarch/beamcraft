package dev.captience.beamcraft.client.mixin;
import java.util.Map;
import net.minecraft.client.renderer.rendertype.*;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;
@Mixin(RenderSetup.class)
public interface RenderSetupAccessor { @Accessor("textures") Map<String, ?> beamcraft$textures(); }
