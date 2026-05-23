from beamngpy import Scenario, Vehicle

CAR_DISTANCE = 40.0

def create_scenario():
    # Create a simple scenario using a standard map. 'smallgrid' is a small
    # empty grid map suitable for testing. If this map is not available in
    # your BeamNG installation, try 'italy' or 'east_coast_usa'.
    scenario = Scenario('smallgrid', 'drivecam_crash_test')

    # Select a stable, common vehicle model. You can change this to any
    # model available in your BeamNG build.
    model = 'etk800'

    # Spawn Vehicle A at negative X facing toward +X
    vehicle_a = Vehicle('vA', model=model, licence='A')
    scenario.add_vehicle(vehicle_a, pos=(-CAR_DISTANCE/2.0, 0, 0), rot_quat=(0, 0, -0.707, 0.707))

    # Spawn Vehicle B at positive X facing toward -X
    vehicle_b = Vehicle('vB', model=model, licence='B')
    scenario.add_vehicle(vehicle_b, pos=(CAR_DISTANCE/2.0, 0, 0), rot_quat=(0, 0, 0.707, 0.707))

    return scenario, (vehicle_a, vehicle_b)


def setup_scenario(scenario, vehicles, bng):
    for vehicle in vehicles:
        vehicle.ai_set_mode('disabled')


def step_scenario(scenario, vehicles, bng, throttle_strength):
    # Both vehicles need to apply forward throttle to drive toward one another
    for vehicle in vehicles:
        # Re-apply throttle each frame to maintain acceleration toward collision
        vehicle.control(throttle=throttle_strength, steering=0.0)
