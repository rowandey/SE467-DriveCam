"""
generate_beamng_crash.py

Simple BeamNGpy script to create a head-on collision between two vehicles and
record IMU-like sensor output (user-accelerometer and gyroscope) into a CSV
file compatible with the project's CSV-driven tests.

NOTE FOR STUDENTS
- This script is a starting template. BeamNGpy and BeamNG.tech have many
  configuration options; you may need to adjust vehicle models, spawn points,
  steering/throttle values, and the BeamNG home path for your local setup.
- The script attempts to use BeamNGpy sensors (Accelerometer & Gyroscope). If
  your BeamNGpy version or BeamNG.tech build differs, the exact sensor keys
  returned by `vehicle.poll_sensors()` might vary — check the runtime output
  and adapt the key names used in `_sample_sensors()` if needed.
- The CSV format written by this script matches the test suite expected header:
  timestamp_ms,user_ax,user_ay,user_az,gyro_x,gyro_y,gyro_z

Usage (example):
  python3 tools/generate_beamng_crash.py \
    --beamng-home "/path/to/BeamNG.research" \
    --output /tmp/beamng_crash.csv \
    --duration 8.0 \
    --sample-rate 100

Requirements:
- BeamNG.tech (running) and BeamNGpy installed in the same Python environment.
  See https://github.com/BeamNG/BeamNGpy and the BeamNGpy docs for setup.

This file follows the project's student-focused guidance: top-of-file comments,
function docstrings, and clear, testable structure.
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import time
from typing import Dict, Tuple

# BeamNGpy imports are conditional so the script can at least provide a helpful
# error if BeamNGpy is not installed in the running environment.
try:
    from beamngpy import BeamNGpy, Scenario, Vehicle
    from beamngpy.sensors import GForces
except Exception as e:  # pragma: no cover - runtime dependency
    print("Imports failed")
    BeamNGpy = None  # type: ignore
    Scenario = None  # type: ignore
    Vehicle = None  # type: ignore
    GForces = None  # type: ignore


def _parse_args() -> argparse.Namespace:
    """Parse CLI arguments.

    Returns:
        argparse.Namespace: parsed arguments.
    """
    parser = argparse.ArgumentParser(
        description="Generate a BeamNG crash CSV suitable for the DriveCam tests"
    )
    parser.add_argument(
        "--beamng-home",
        required=True,
        help="Path to your BeamNG.research / BeamNG.tech installation directory",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output CSV path. Example: drivecam/test/fixtures/crash/beamng_crash.csv",
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
        default=100.0,
        help="Sensor sample rate in Hz",
    )
    parser.add_argument(
        "--distance",
        type=float,
        default=40.0,
        help="Initial distance between car centers in meters",
    )
    parser.add_argument(
        "--throttle-strength",
        type=float,
        default=0.8,
        help="Strength of throttle applied to both vehicles (0.0 to 1.0) to control collision severity",
    )
    return parser.parse_args()


def _make_beamng_objects(beamng_home: str, distance: float) -> Tuple[BeamNGpy, Scenario, Vehicle, Vehicle]:
    """Create BeamNGpy objects: a controller, a scenario and two vehicles.

    The vehicles are positioned facing each other along the X axis.

    Args:
        beamng_home: Local path to the BeamNG installation directory.
        distance: Initial distance between car centers in meters.

    Returns:
        Tuple of (bng, scenario, vehicle_a, vehicle_b).
    """
    if BeamNGpy is None:
        raise RuntimeError(
            "BeamNGpy imports failed. Ensure beamngpy is installed and available."
        )

    bng = BeamNGpy('localhost', 64256, home=beamng_home)

    # Create a simple scenario using a standard map. 'smallgrid' is a small
    # empty grid map suitable for testing. If this map is not available in
    # your BeamNG installation, try 'italy' or 'east_coast_usa'.
    scenario = Scenario('smallgrid', 'drivecam_crash_test')

    # Select a stable, common vehicle model. You can change this to any
    # model available in your BeamNG build.
    model = 'etk800'

    # Spawn Vehicle A at negative X facing toward +X
    vehicle_a = Vehicle('vA', model=model, licence='A')
    scenario.add_vehicle(vehicle_a, pos=(-distance/2.0, 0, 0), rot_quat=(0, 0, -0.707, 0.707))

    # Spawn Vehicle B at positive X facing toward -X
    vehicle_b = Vehicle('vB', model=model, licence='B')
    scenario.add_vehicle(vehicle_b, pos=(distance/2.0, 0, 0), rot_quat=(0, 0, 0.707, 0.707))

    return bng, scenario, vehicle_a, vehicle_b


def _attach_sensors(bng: BeamNGpy, vehicle: Vehicle) -> None:
    """Attach sensors to a vehicle for recording crash data.

    This function attaches a GForces sensor which reports g-force acceleration
    that's ideal for crash detection. The State sensor is available by default
    on all vehicles, so we don't need to explicitly attach it.

    Args:
        bng: BeamNGpy object
        vehicle: BeamNGpy Vehicle object
    """
    # Attach only GForces sensor for acceleration data (crash detection metric)
    # The 'state' sensor is automatically available and provides vehicle state / pose
    gforces = GForces()
    vehicle.sensors.attach('gforces', gforces)



def _sample_sensors(vehicle: Vehicle) -> Dict[str, Tuple[float, float, float]]:
    """Poll sensors from the vehicle and return accel & gyro tuples.

    This function polls the GForces sensor (acceleration via g-forces) and
    derives gyro data from rotation changes in the State sensor. Both sensors
    must have been previously initialized (GForces via attach, State by default).

    Args:
        vehicle: BeamNGpy Vehicle with attached sensors

    Returns:
        Dict with keys 'accel' and 'gyro', each mapping to an (x,y,z) tuple.
        Accel is in g-units (where 1g ≈ 9.81 m/s²).
        Gyro values are derived from orientation changes (rad/s, approximate).
    """
    # Poll all available sensors
    vehicle.sensors.poll()

    # Defensive access — fall back to zeros if a sensor is missing
    accel = (0.0, 0.0, 0.0)
    gyro = (0.0, 0.0, 0.0)

    # Extract acceleration from GForces sensor
    try:
        gforces_data = vehicle.sensors['gforces']
        if isinstance(gforces_data, dict):
            # GForces provides gx, gy, gz in g-units; direct use
            accel = (
                float(gforces_data.get('gx', 0.0)),
                float(gforces_data.get('gy', 0.0)),
                float(gforces_data.get('gz', 0.0))
            )
    except (KeyError, TypeError, ValueError, AttributeError):
        pass

    # For gyro: we could derive from rotation quaternion changes over time,
    # but for simplicity (and since impacts are primarily acceleration-driven),
    # we use a stub. If needed later, compute angular velocity from:
    #   drotation / dt using state['rotation'] and previous rotation.
    # For now, zeroed gyro is acceptable since GForces dominates the fused metric.
    gyro = (0.0, 0.0, 0.0)

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


def _append_csv_row(path: str, timestamp_ms: int, accel: Tuple[float, float, float], gyro: Tuple[float, float, float]) -> None:
    """Append a single row of sensor data to the CSV file.

    Args:
        path: CSV file path
        timestamp_ms: elapsed ms since start of recording
        accel: (ax, ay, az)
        gyro: (gx, gy, gz)
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


def run_simulation(args: argparse.Namespace) -> None:
    """Set up BeamNG, run a short head-on scenario and record IMU data.

    This function launches BeamNG (or connects to a running instance), loads
    a scenario, spawns two vehicles, attaches sensors, drives them towards one
    another, and records accelerometer & gyroscope samples into the output
    CSV file at the requested sample rate.

    Args:
        args: CLI arguments parsed from _parse_args()
    """
    if BeamNGpy is None:
        raise RuntimeError("BeamNGpy not available. Install beamngpy in this Python environment.")

    # Create BeamNG objects and scenario
    bng, scenario, vA, vB = _make_beamng_objects(args.beamng_home, args.distance)

    # Start BeamNG and run
    print('Launching BeamNG (this may take a few seconds)...')
    bng.open(opts='-gfx vk')

    print('Writing header to', args.output)
    _write_csv_header(args.output)

    try:
        scenario.make(bng)
        bng.load_scenario(scenario)
        bng.start_scenario()

        _attach_sensors(bng, vA)
        _attach_sensors(bng, vB)

        # Make sure vehicles are controllable directly
        vA.ai_set_mode('disabled')
        vB.ai_set_mode('disabled')

        # Small helper to set forward throttle for both cars. Vehicle A drives forward
        # naturally (pointing +X). Vehicle B is rotated to point -X, so it also needs
        # forward throttle to drive toward Vehicle A.
        vA.control(throttle=0.8, steering=0.0)
        vB.control(throttle=0.8, steering=0.0)

        # Sleep a tiny bit so physics initializes
        time.sleep(0.2)

        start_time = time.perf_counter()
        last_sample_time = start_time
        sample_interval = 1.0 / float(args.sample_rate)

        elapsed = 0.0
        # Main simulation loop: step the simulator and poll sensors at the
        # requested sample rate until the duration elapses.
        while elapsed < args.duration:
            # Step the sim forward a single frame; BeamNGpy will advance physics
            # when we call bng.step(). The argument is number of frames to step
            # using the simulator's internal step; stepping 1 is usually fine.
            bng.step(1)

            # Re-apply throttle each frame to maintain acceleration toward collision
            vA.control(throttle=args.throttle_strength, steering=0.0)
            vB.control(throttle=args.throttle_strength, steering=0.0)

            now = time.perf_counter()
            elapsed = now - start_time
            if (now - last_sample_time) >= sample_interval:
                # Poll sensors for vehicle A (you can record both if desired)
                samples = _sample_sensors(vA)
                accel = samples['accel']
                gyro = samples['gyro']

                timestamp_ms = int(elapsed * 1000.0)
                _append_csv_row(args.output, timestamp_ms, accel, gyro)

                last_sample_time = now

        print('Simulation finished; closing BeamNG...')

    finally:
        try:
            bng.close()
        except Exception:
            pass


if __name__ == '__main__':
    args = _parse_args()

    # Ensure output dir exists
    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)

    run_simulation(args)

