// Settings from the [default.simulator] table in config/config.toml.
// Kept apart from SimulatorTypes, because the app's config types depend on it.
type simulatorConfig = {
  simUrl: string,
  orgId: string,
  merchantId: string,
  profileId: string,
}
