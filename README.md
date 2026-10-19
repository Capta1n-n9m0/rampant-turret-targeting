# Rampant Turret Targeting

A Factorio 2.1 mod that fills the target priority lists of gun, laser and flamethrower turrets, tuned for the
enemies of [RampantFixed](https://mods.factorio.com/mod/RampantFixed): every turret type shoots first at what is
most dangerous and what it actually hurts.

Mod portal: <https://mods.factorio.com/mod/rampant-turret-targeting>

## What it does

- **Shortcut button** "Apply Rampant turret targeting to all turrets": sets the lists on every gun, laser and
  flamethrower turret of your force, on every surface.
- **Auto-apply on build**: turrets built by players, construction robots or scripts get their list right away.
  Runtime setting *Auto-apply targeting to newly built turrets* (on by default).
- **Hero turrets**: ranked turrets of [HeroTurretRedux](https://mods.factorio.com/mod/HeroTurretRedux) or
  [HeroTurretsReduxFork](https://mods.factorio.com/mod/HeroTurretsReduxFork) (`hero-turret-<rank>-for-<turret>`)
  use the list of their base turret, and keep it when they rank up.
- Enemies that don't exist in your game (other faction settings, no ArmouredBiters) are left out of the lists, and
  slots after the end of a list are cleared. Other turret types are not touched.

The lists only set priorities; turrets still shoot at anything else in range unless you tick *ignore unprioritised
targets* on them yourself.

## How the lists are made

`scripts/targeting.py` holds a table of the Rampant faction units and the
[ArmouredBiters](https://mods.factorio.com/mod/ArmouredBiters) snappers with their damage multipliers against
bullets, laser and fire (from RampantFixed 2.2.8 and ArmouredBiters 2.0.2) and a danger score. For each turret
type it drops the units the turret barely hurts (under 0.35x), puts nuclear and suicide biters first wherever the
turret does full damage to them, and orders the rest by danger times effectiveness, highest tier first.

Run it from the repository root to regenerate the mod's `targeting-data.lua` and a readable
`out/targeting-report.md`:

```
python scripts/targeting.py [blueprint.txt] [--tiers 1-10] [--max N]
```

With a blueprint string file it also writes a copy of the blueprint with the lists stamped on every turret, and a
console command for already-built turrets.

## Remote interface

```lua
remote.call("rampant-turret-targeting", "apply", force_name)  -- same as the shortcut; returns the number of turrets set
remote.call("rampant-turret-targeting", "last_apply")         -- {tick, source, force, player, matched, turrets, first_error} or nil
remote.call("rampant-turret-targeting", "is_applied", turret) -- true if the turret holds exactly the list
```

`source` is `"shortcut"` or `"remote"`; `player` is set for the shortcut. `force_name` defaults to `"player"`.

## Requirements

Factorio 2.1 and RampantFixed. Optional: ArmouredBiters, HeroTurretRedux, HeroTurretsReduxFork.

## Development

The mod lives in `mod/rampant-turret-targeting/`. Its tests are a
[FactorioTest](https://github.com/GlassBricks/FactorioTest) suite in `mod/rampant-turret-targeting/tests/`; they
load only when the `factorio-test` mod is active, so they never run in a normal game. They work on their own
surface and force, so they can also run on a loaded save. Run them with the FactorioTest CLI, for example

```
npx -p factorio-test-cli factorio-test run --mod-path mod/rampant-turret-targeting --mods HeroTurretRedux ArmouredBiters
```

`tests/autotest.json` lists the mod sets the suite is run with before a release (minimal, with HeroTurretRedux and
ArmouredBiters, with HeroTurretsReduxFork, and a full modpack).

## License

MIT, see `LICENSE`.
