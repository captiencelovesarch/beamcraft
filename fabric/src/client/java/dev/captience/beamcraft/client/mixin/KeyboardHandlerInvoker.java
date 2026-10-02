package dev.captience.beamcraft.client.mixin;

import net.minecraft.client.KeyboardHandler;
import net.minecraft.client.input.CharacterEvent;
import net.minecraft.client.input.KeyEvent;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Invoker;

/** Feed BeamNG's keyboard into Minecraft exactly as GLFW would (for screens: chat, inventory search...). */
@Mixin(KeyboardHandler.class)
public interface KeyboardHandlerInvoker {
	@Invoker("keyPress")
	void beamcraft$keyPress(long handle, int action, KeyEvent event);

	@Invoker("charTyped")
	void beamcraft$charTyped(long handle, CharacterEvent event);
}
