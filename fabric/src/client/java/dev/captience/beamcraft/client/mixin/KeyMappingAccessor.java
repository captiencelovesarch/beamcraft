package dev.captience.beamcraft.client.mixin;

import net.minecraft.client.KeyMapping;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(KeyMapping.class)
public interface KeyMappingAccessor {
	@Accessor("clickCount")
	int beamcraft$getClickCount();

	@Accessor("clickCount")
	void beamcraft$setClickCount(int count);
}
