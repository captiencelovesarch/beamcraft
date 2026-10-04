# BeamCraft

**Play Minecraft inside BeamNG.drive.** Walk around a BeamNG map as Steve, punch blocks, build, fight mobs, then hop in a car and drive straight through what you built.

BeamCraft runs a real Minecraft Java client hidden in the background. Minecraft does all the gameplay: movement, inventory, blocks, mobs, combat, the HUD. BeamNG renders it all in its own world, with its own physics. Your blocks are solid to cars, cars hit mobs, explosions dent cars, and the hotbar, inventory and chat are Minecraft's own screens drawn over BeamNG.

Inspired by [SkyCraft](https://github.com/chasmlol/SkyCraft) (Minecraft inside Skyrim).

> **Alpha.** It's playable start to finish, but this is a first public release. Expect rough edges, and please [report bugs](../../issues).

## What works

- **Steve in BeamNG.** Vanilla movement, sprinting, crouching, jumping, swimming, elytra. First and third person (F5). Your own skin and cape.
- **Building.** Place and break blocks anywhere on any BeamNG map. Blocks keep Minecraft's textures and are solid to cars.
- **Minecraft's own UI.** Hotbar, health, hunger, inventory, crafting, chests and chat are the real Minecraft screens, mouse and keyboard included.
- **Mobs.** Real Minecraft mob models and animations. They spawn, wander, path over BeamNG's terrain and fight you. Turn spawning off with `/beamcraft mobs off`.
- **Cars vs Minecraft.** Cars knock blocks and mobs around and take damage from them. Hits, explosions and weapons dent cars (mace and sword hits included), wind charges shove them, and enchantments carry over to cars.
- **Sound.** Minecraft's sounds play in 3D from where they happen in BeamNG.
- **Particles, items and projectiles,** all hitting BeamNG's ground.
- **One world per map.** Each BeamNG level gets its own Minecraft save, so your builds stay where you left them.

## Requirements

- **Linux.** BeamCraft is built and tested on Linux (Arch, KDE Plasma on Wayland, AMD GPU) with BeamNG.drive's native Linux build. Windows is **untested** and probably doesn't work yet.
- **BeamNG.drive** 0.39 (native Linux build).
- **Minecraft Java Edition.** You need to own it.
- **Java 25** (a JDK, e.g. `jdk25-openjdk` on Arch, `openjdk-25-jdk` on Debian/Ubuntu).
- **Git.**
- About **3 GB of free RAM** for the hidden Minecraft, on top of BeamNG.

The first launch downloads Minecraft 26.2, Fabric and their dependencies (a few hundred MB).

## Install

**1. Get BeamCraft**

```bash
git clone https://github.com/captiencelovesarch/beamcraft.git
cd beamcraft
```

**2. Install the BeamNG mod**

```bash
tools/deploy.sh
```

This copies the `beamng/` folder into your BeamNG userfolder as `mods/unpacked/beamcraft`. If your userfolder isn't in the default place (`~/.local/share/BeamNG/BeamNG.drive/current`), copy `beamng/` there yourself.

**3. Point the backend at your Java 25**

`tools/run_backend.sh` uses `/usr/lib/jvm/java-25-openjdk`. If your Java 25 lives somewhere else, change the `JAVA_HOME` line in that file.

## Play

1. **Start the hidden Minecraft:**
   ```bash
   tools/run_backend.sh
   ```
   Leave this terminal open. No Minecraft window will appear; that's on purpose. The first start takes a few minutes (downloads); after that, about a minute.
2. **Start BeamNG.drive** and load any map. BeamCraft connects by itself.
3. **Press Alt+B** to step out as Steve. Press Alt+B again (or get in a car) to go back to driving.

Order doesn't matter: start BeamNG first and BeamCraft connects as soon as the backend is up.

To quit, close BeamNG, then stop the backend with **Ctrl+C** in its terminal.

## Controls

These are the defaults. Rebind them in BeamNG's controls options: they're under **Gameplay**, all starting with "BeamCraft:".

| Key | Action |
|---|---|
| Alt+B | Step out as Steve / back to driving |
| WASD + mouse | Move and look |
| Space | Jump |
| Left Shift | Sneak |
| Left Ctrl | Sprint |
| Left click | Attack / break |
| Right click | Use / place |
| Middle click | Pick block |
| Scroll, 1-9 | Hotbar |
| E | Inventory |
| Q | Drop item |
| T | Chat |
| / | Command |
| F5 | First / third person |

Commands work like in Minecraft. Creative mode, for building: `/gamemode creative`.

## Your skin and cape

The hidden Minecraft plays offline, so it can't fetch your skin. Give it one:

- **Skin:** put a 64×64 skin PNG at `fabric/run/beamcraft/skin.png`. Slim or wide arms are detected automatically.
- **Cape:** put a cape PNG at `fabric/run/beamcraft/cape.png`.

Restart the backend to pick them up.

## Troubleshooting

**BeamCraft doesn't connect / Alt+B does nothing.** Check the backend terminal is still running and finished loading. BeamNG and Minecraft talk on `127.0.0.1` ports **47800** and **47802**; make sure nothing else uses them.

**"Address already in use" when starting the backend.** An old hidden Minecraft is still running (it ignores normal shutdown signals). Find it and kill it:
```bash
pkill -9 -f beamcraft.headless
```

**Low fps.** The hidden Minecraft costs real GPU and CPU time, most of all in big fights. BeamCraft already limits it while you drive. Lower BeamNG's graphics settings, or turn mob spawning off with `/beamcraft mobs off`.

**A short hitch when blocks change near a moving car.** BeamNG rebuilds its collision so the car can hit the new blocks. Known, and being worked on.

**The mod vanished from BeamNG.** Don't delete `mods/unpacked/beamcraft` while BeamNG is running. If it happens, restart BeamNG.

**Where are my worlds?** In `fabric/run/saves/`, one `beamcraft_<map>` folder per BeamNG map.

## How it works

```
 Minecraft 26.2 + Fabric (hidden)          BeamNG.drive
 ────────────────────────────────          ────────────
 player, blocks, mobs, inventory  ──TCP──▶  world meshes, mobs, particles, sound
 HUD + screens (read back as tiles) ─────▶  imgui overlay
 world queries (ground, cars)      ◀──TCP──  terrain raycasts, car positions, input
```

- **`fabric/`**: the Minecraft half, a Fabric mod for Minecraft 26.2. Minecraft keeps doing everything except drawing the world. It streams blocks, entity models, particles and sounds to BeamNG, and reads back its own HUD and screens.
- **`beamng/`**: the BeamNG half, an unpacked mod. It builds meshes for blocks and mobs, runs the camera, draws the HUD, forwards your input to Minecraft, and answers Minecraft's questions about BeamNG's ground and cars.
- **`tools/`**: launch, deploy and test scripts.

They talk over newline-delimited JSON on `127.0.0.1:47800`. Coordinates are shared, one block = one metre.

## Building from source

`tools/run_backend.sh` already builds and runs from source. To build just the Fabric jar:

```bash
cd fabric
JAVA_HOME=/usr/lib/jvm/java-25-openjdk ./gradlew build
```

The jar lands in `fabric/build/libs/`. Protocol test (no BeamNG needed): start `tools/run_backend.sh`, then run `tools/fake_beamng.py --userpath /tmp/bc-user`.

## License

[MIT](LICENSE). Minecraft is a trademark of Mojang AB and BeamNG.drive of BeamNG GmbH; BeamCraft isn't affiliated with or endorsed by either. No Minecraft or BeamNG assets are included in this repository.
