package dev.captience.beamcraft.mixin;

import com.google.gson.JsonObject;
import dev.captience.beamcraft.Bridge;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.ServerExplosion;
import net.minecraft.world.phys.Vec3;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/** TNT and creepers also throw BeamNG's cars around: tell BeamNG about every blast. */
@Mixin(ServerExplosion.class)
public abstract class ServerExplosionMixin {
	@Inject(method = "explode", at = @At("HEAD"))
	private void beamcraft$announce(CallbackInfoReturnable<Integer> cir) {
		ServerExplosion self = (ServerExplosion) (Object) this;
		if (self.level().dimension() != Level.OVERWORLD || !Bridge.isConnected()) return;
		Vec3 c = self.center();
		JsonObject o = new JsonObject();
		o.addProperty("t", "boom");
		o.addProperty("x", c.x);
		o.addProperty("y", c.y);
		o.addProperty("z", c.z);
		o.addProperty("r", self.radius());
		// wind charges (and breezes) are gusts: they only trigger blocks, never break them
		if (self.getBlockInteraction() == net.minecraft.world.level.Explosion.BlockInteraction.TRIGGER_BLOCK) o.addProperty("wind", true);
		Bridge.send(o);
	}
}
