package dev.captience.beamcraft.client.mixin;
import java.util.Queue;
import net.minecraft.client.particle.*;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;
@Mixin(ParticleGroup.class)
public interface ParticleGroupAccessor {
 @Accessor("particles") Queue<Particle> beamcraft$particles();
}
