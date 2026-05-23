from __future__ import annotations

import argparse
import csv
import importlib.util
import os
import sys
from typing import Dict, Tuple

# BeamNGpy imports are conditional so the script can at least provide a helpful
# error if BeamNGpy is not installed in the running environment.
try:
    from beamngpy import BeamNGpy, Scenario, Vehicle, ProceduralCube
    from beamngpy.sensors import AdvancedIMU, Timer
except ImportError:  # pragma: no cover - runtime dependency
    print("Imports failed")
    BeamNGpy = None  # type: ignore
    Scenario = None  # type: ignore
    Vehicle = None  # type: ignore
    ProceduralCube = None  # type: ignore
    AdvancedIMU = None  # type: ignore
    Timer = None


def _parse_args() -> argparse.Namespace:
    """Parse CLI arguments.

    Returns:
        argparse.Namespace: parsed arguments.
    """
    parser = argparse.ArgumentParser(
        description="Generate a BeamNG wall-crash CSV suitable for the DriveCam tests"
    )
    parser.add_argument(
        "--beamng-home",
        required=True,
        help="Path to your BeamNG installation directory",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output CSV path. Example: drivecam/test/fixtures/crash/beamng_wall_crash.csv",
    )
    parser.add_argument(
        "--scenario",
        required=True,
        help="Scenario script path. Scenario scripts must define `create_scenario`, `setup_scenario`, and `step_scenario` functions.",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=8.0,
        help="Simulation duration in seconds",
    )
    parser.add_argument(
        "--sample-rate",
        type=float,
        default=50.0,
        help="Sensor sample rate in Hz",
    )
    parser.add_argument(
        "--throttle-strength",
        type=float,
        default=0.8,
        help="Throttle strength applied to the vehicle (0.0 to 1.0)",
    )
    parser.add_argument(
        "--headless",
        action='store_true',
        default=False,
        help="Disables graphics for faster execution."
    )
    return parser.parse_args()


def _connect_to_beamng(beamng_home: str) -> BeamNGpy:
    """Creates a BeamNGpy connection
    Args:
        beamng_home: Local path to the BeamNG installation directory.

    Returns:
        A connected BeamNGpy instance ready to run the scenario.
    """
    if BeamNGpy is None:
        raise RuntimeError(
            "BeamNGpy imports failed. Ensure beamngpy is installed and available."
        )

    bng = BeamNGpy('localhost', 64256, home=beamng_home, headless=args.headless)

    return bng


def _attach_sensors(bng: BeamNGpy, vehicle: Vehicle) -> Tuple[AdvancedIMU, Timer]:
    """Create an `AdvancedIMU` sensor and a `Timer` sensor for one vehicle.

    `AdvancedIMU` opens itself against the vehicle when constructed, so this
    helper returns the IMU sensor directly, while `Timer` is attached through
    the vehicle sensor container so we can read simulation time from BeamNG.

    Args:
        bng: BeamNGpy object.
        vehicle: BeamNGpy Vehicle object.

    Returns:
        A tuple of `(AdvancedIMU, Timer)` sensors.
    """
    # Use one IMU sensor to capture both acceleration and angular velocity.
    imu = AdvancedIMU(
        'imu',
        bng,
        vehicle,
        physics_update_time=0.01,
        is_send_immediately=True,
        is_visualised=False,
    )

    # The Timer sensor tracks simulation time, which keeps sampling aligned to
    # the scenario clock instead of the wall clock.
    timer = Timer()
    vehicle.sensors.attach('timer', timer)

    return imu, timer


def _vector_from_reading(reading: Dict[str, object], field_name: str) -> Tuple[float, float, float]:
    """Extract an `(x, y, z)` triplet from an IMU reading.

    Args:
        reading: One AdvancedIMU reading dictionary.
        field_name: The field to extract, such as `accRaw` or `angVel`.

    Returns:
        A three-value tuple with zeros as a fallback.
    """
    value = reading.get(field_name)
    if isinstance(value, dict):
        return (
            float(value.get('x', 0.0)),
            float(value.get('y', 0.0)),
            float(value.get('z', 0.0)),
        )
    if isinstance(value, (list, tuple)) and len(value) >= 3:
        return float(value[0]), float(value[1]), float(value[2])
    return 0.0, 0.0, 0.0


def _latest_imu_reading(readings: object) -> Dict[str, object]:
    """Normalize AdvancedIMU polling output to a single reading dictionary.

    Args:
        readings: Raw value returned by `AdvancedIMU.poll()`.

    Returns:
        The newest reading dictionary, or an empty dictionary if no reading was
        available.
    """
    if isinstance(readings, dict):
        if 'accRaw' in readings or 'angVel' in readings or 'accSmooth' in readings:
            return readings
        if readings:
            latest_key = next(reversed(readings))
            latest_value = readings.get(latest_key)
            if isinstance(latest_value, dict):
                return latest_value
    if isinstance(readings, list) and readings:
        latest_value = readings[-1]
        if isinstance(latest_value, dict):
            return latest_value
    return {}


def _read_simulation_time(vehicle: Vehicle) -> float:
    """Poll the Timer sensor and return the current simulation time.

    Args:
        vehicle: BeamNGpy vehicle whose `timer` sensor is attached.

    Returns:
        The simulation time in seconds, or `0.0` if the timer data is not
        available yet.
    """
    # Polling only the Timer sensor keeps this helper lightweight and makes the
    # loop easier to reason about.
    vehicle.sensors.poll('timer')
    try:
        return float(vehicle.sensors['timer']['time'])
    except (KeyError, TypeError, ValueError):
        return 0.0


def _sample_sensors(imu: AdvancedIMU) -> Dict[str, Tuple[float, float, float]]:
    """Poll the IMU sensor and return accel and gyro tuples.

    The wall generator now uses the same IMU sensor for both acceleration and
    angular velocity so the CSV contains a realistic gyroscope signal.

    Args:
        imu: An `AdvancedIMU` sensor attached to the vehicle.

    Returns:
        Dict with keys 'accel' and 'gyro', each mapping to an `(x, y, z)` tuple.
    """
    # AdvancedIMU.poll() may return one reading or multiple readings. We use the
    # latest reading so the CSV still contains one line per sample interval.
    reading = _latest_imu_reading(imu.poll())
    accel = _vector_from_reading(reading, 'accRaw')
    gyro = _vector_from_reading(reading, 'angVel')
    return {'accel': accel, 'gyro': gyro}


def _write_csv_header(path: str) -> None:
    """Write the CSV header expected by the tests.

    Args:
        path: file path to write header to (overwrites any existing file).
    """
    with open(path, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow([
            'timestamp_ms',
            'user_ax',
            'user_ay',
            'user_az',
            'gyro_x',
            'gyro_y',
            'gyro_z',
        ])


def _append_csv_row(
        path: str,
        timestamp_ms: int,
        accel: Tuple[float, float, float],
        gyro: Tuple[float, float, float],
) -> None:
    """Append a single row of sensor data to the CSV file.

    Args:
        path: CSV file path.
        timestamp_ms: elapsed ms since start of recording.
        accel: (ax, ay, az).
        gyro: (gx, gy, gz).
    """
    with open(path, 'a', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow([
            int(timestamp_ms),
            float(accel[0]),
            float(accel[1]),
            float(accel[2]),
            float(gyro[0]),
            float(gyro[1]),
            float(gyro[2]),
        ])

def run_simulation(sim_args: argparse.Namespace) -> None:
    """Set up BeamNG, run a wall-impact scenario, and record sensor data.

    This function launches BeamNG (or connects to a running instance), loads a
    scenario, spawns one vehicle, places a static wall in front of it, drives
    the vehicle toward the wall, and records sensor samples into the output CSV
    file at the requested sample rate.

    Args:
        sim_args: CLI arguments parsed from _parse_args().
    """
    if BeamNGpy is None:
        raise RuntimeError("BeamNGpy not available. Install beamngpy in this Python environment.")

    # Create BeamNG objects and scenario.
    bng = _connect_to_beamng(sim_args.beamng_home)

    if not os.path.isfile(sim_args.scenario):
        raise FileNotFoundError(f"Scenario script not found: {sim_args.scenario}")

    spec = importlib.util.spec_from_file_location("scenario_module", sim_args.scenario)
    scenario_module = importlib.util.module_from_spec(spec)
    sys.modules["scenario_module"] = scenario_module
    spec.loader.exec_module(scenario_module)

    scenario, vehicles = scenario_module.create_scenario()

    print('Launching BeamNG (this may take a few seconds)...')
    bng.open()

    print('Writing header to', sim_args.output)
    _write_csv_header(sim_args.output)

    try:
        scenario.make(bng)
        bng.load_scenario(scenario)
        bng.start_scenario()

        bng.pause()
        bng.settings.set_deterministic(args.sample_rate)

        imu, _timer = _attach_sensors(bng, vehicles[0])

        # Step once to ensure sensors are initialized
        bng.step(1)

        scenario_module.setup_scenario(scenario, vehicles, bng)

        bng.resume()

        # Set up data export timing from BeamNG simulation time.
        start_time = _read_simulation_time(vehicles[0])
        last_sample_time = start_time
        sample_interval = 1.0 / float(sim_args.sample_rate)

        # Run the scenario
        elapsed = 0.0
        while elapsed < sim_args.duration:
            # Step the sim forward one frame. This keeps the physics and sensor
            # updates in sync with the replay data we want to capture.
            # bng.step(1)

            print(f"Sim time: {elapsed:.2f}s / {sim_args.duration:.2f}s")

            scenario_module.step_scenario(scenario, vehicles, bng, sim_args.throttle_strength)

            # Use the simulation clock rather than the system clock so paused or
            # slowed scenarios do not distort the exported timestamps.
            now = _read_simulation_time(vehicles[0])
            elapsed = now - start_time
            if (now - last_sample_time) >= sample_interval:
                samples = _sample_sensors(imu)
                accel = samples['accel']
                gyro = samples['gyro']

                timestamp_ms = int(elapsed * 1000.0)
                _append_csv_row(sim_args.output, timestamp_ms, accel, gyro)

                last_sample_time = now

        print('Simulation finished; closing BeamNG...')

    finally:
        bng.close()


if __name__ == '__main__':
    args = _parse_args()

    # Ensure output dir exists.
    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)

    run_simulation(args)
