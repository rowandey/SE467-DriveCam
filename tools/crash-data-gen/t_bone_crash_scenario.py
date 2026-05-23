from beamngpy import Scenario, Vehicle

CAR_DISTANCE = 40.0

def create_scenario():
    scenario = Scenario('smallgrid', 'drivecam_t_bone_test')
    model = 'etk800'

    # Spawn Vehicle A to the left of the intersection, facing +X
    vehicle_a = Vehicle('vA', model=model, licence='A')
    scenario.add_vehicle(
        vehicle_a,
        pos=(CAR_DISTANCE / 2.0 , 0, 0),
        rot_quat=(0, 0, 0.707, 0.707),
    )

    # Spawn Vehicle B below the intersection, facing +Y
    vehicle_b = Vehicle('vB', model=model, licence='B')
    scenario.add_vehicle(
        vehicle_b,
        pos=(0, CAR_DISTANCE / 2.0 + 3, 0),
        rot_quat=(0, 0, 0, 1),
    )

    return scenario, (vehicle_a, vehicle_b)


def setup_scenario(scenario, vehicles, bng):
    for vehicle in vehicles:
        vehicle.ai_set_mode('disabled')


def step_scenario(scenario, vehicles, bng, throttle_strength):
    # Hardcoded throttle strength for both vehicles to ensure they collide
    vehicles[0].control(throttle=0.8, steering=0.0)
    vehicles[1].control(throttle=0.8, steering=0.0)

