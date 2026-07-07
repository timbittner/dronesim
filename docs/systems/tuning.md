# Tuning Parameters

Part of the DroneSim reference; see [PROJECT_SUMMARY.md](../../PROJECT_SUMMARY.md) for the index.

| Parameter | Location | Value |
|---|---|---|
| max_thrust (per rotor) | drone_controller.gd | 17.5 N |
| hover_throttle (per rotor) | drone_controller.gd | 0.28 (auto, at 2.0 kg mass) |
| Angular damping | drone_controller.gd | (0.08, 1.0, 0.08) |
| MIN_ROTOR | drone_controller.gd | 0.02 |
| Acro idle_throttle | flight_mode_acro.gd | 0.08 |
| Acro max_differential | flight_mode_acro.gd | 0.057 |
| Acro pitch_roll_expo | flight_mode_acro.gd | 0.3 |
| Acro yaw_torque_factor | flight_mode_acro.gd | 1.5 |
| Stab P gain | flight_mode_stabilized.gd | 15.0 |
| Stab D gain | flight_mode_stabilized.gd | 4.0 |
| Stab rate_P gain | flight_mode_stabilized.gd | 4.0 |
| Stab max rates | flight_mode_stabilized.gd | 1.5 / 1.5 / 1.0 rad/s |
| Stab input deadzone | flight_mode_stabilized.gd | 0.05 |
| Stab blend_band | flight_mode_stabilized.gd | 0.2 |
| Stab gyro_filter_alpha (auto-level D filter) | flight_mode_stabilized.gd | 0.35, range 0.0–1.0 |
| Stab rate_gyro_filter_alpha (rate-loop filter) | flight_mode_stabilized.gd | 0.5, range 0.0–1.0 |
| FPV rotation smoothing | chase_camera.gd | 0.92 |
| Chase distance / height | chase_camera.gd | 2.2 m / 0.9 m |
| Crash momentum threshold | drone_controller.gd | 8.0 kg·m/s |
| Crash max impact angle | drone_controller.gd | 60° |
| Altitude hold P gain | flight_mode_altitude_hold.gd | 0.15 |
| Altitude hold D gain | flight_mode_altitude_hold.gd | 0.3 |
| Altitude hold release blend time | flight_mode_altitude_hold.gd | 0.3 s |
| Brake P gain | brake_assist.gd | 6.0 |
| Brake D gain | brake_assist.gd | 1.5 |
| Brake max tilt | brake_assist.gd | 25° |
| Brake time constant | brake_assist.gd | 1.0 s |
| air_drag_coefficient | drone_controller.gd | 1.0 N·s/m |
| WindField wind_direction_deg | wind_field.gd | 70.0° (0° = −Z) |
| WindField base_speed | wind_field.gd | 6.0 m/s |
| WindField boundary_layer_height | wind_field.gd | 35.0 m AGL |
| WindField ground_wind_fraction | wind_field.gd | 0.35 |
| WindField shelter_strength | wind_field.gd | 0.95 |
| WindField shadow_angle_deg | wind_field.gd | 22.0° |
| WindField deflection_strength | wind_field.gd | 1.2 |
| WindField updraft_strength | wind_field.gd | 0.6 |
| WindField ridge_boost | wind_field.gd | 0.35 |
| WindField ridge_reference_height | wind_field.gd | 12.0 m |
| WindField turbulence_strength | wind_field.gd | 0.25 |
| WindField direction_wobble_deg | wind_field.gd | 12.0° |
| WindField calm_radius / calm_falloff | wind_field.gd | 18.0 m / 12.0 m |
| WindParticles streak_count | wind_particles.gd | 300 |
| WindParticles volume_extents | wind_particles.gd | (45, 25, 45) m |
| WindParticles resample_interval | wind_particles.gd | 4 frames |
| Kamikaze dive_angle_deg (glideslope) | follower_pilot.gd | 35.0°, range ~15–60° |
| Kamikaze strike_altitude (climb-before-dive floor) | follower_pilot.gd | 6.0 m, range ~6–20 |
| Sink cap min_sink_rate | flight_mode_formation.gd | 2.0 m/s, range ~1.5–4 |
| Sink cap agl_sink_gain | flight_mode_formation.gd | 0.5, range ~0.2–1.0 |
| Sink cap sink_arrest_gain | flight_mode_formation.gd | 0.1, range ~0.05–0.3 |
| Prop obstruction prop_radius | drone_controller.gd | 0.12 m, range ~0.09–0.14 |
| Prop obstruction prop_disc_height | drone_controller.gd | 0.04 m, range ~0.02–0.08 |
| Prop obstruction prop_break_speed | drone_controller.gd | 3.0 m/s, range ~2–5 |
| Prop obstruction show_prop_debug | drone_controller.gd | false (inspector + HUD "PROP DBG" toggle) |
| Stranded self-destruct stranded_timeout | follower_pilot.gd | 10.0 s |
| Swarm altitude_offset (P6.6 clearance bump) | swarm_manager.gd | 1.5 m (was 0.0) |
