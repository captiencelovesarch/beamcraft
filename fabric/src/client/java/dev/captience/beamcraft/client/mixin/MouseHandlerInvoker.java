package dev.captience.beamcraft.client.mixin;

import net.minecraft.client.MouseHandler;
import net.minecraft.client.input.MouseButtonInfo;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Invoker;

/** Feed BeamNG's mouse into Minecraft exactly as GLFW would. */
@Mixin(MouseHandler.class)
public interface MouseHandlerInvoker {
	@Invoker("onButton")
	void beamcraft$onButton(long handle, MouseButtonInfo button, int action);

	@Invoker("onMove")
	void beamcraft$onMove(long handle, double x, double y);

	@Invoker("onScroll")
	void beamcraft$onScroll(long handle, double dx, double dy);
}
