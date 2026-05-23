from beamngpy import Scenario, Vehicle, ProceduralCube

WALL_DISTANCE = 20.0

def create_scenario():
    # A small test map keeps the setup simple and makes it easier to reason
    # about the crash geometry.
    scenario = Scenario('smallgrid', 'drivecam_wall_test')

    # Use the same common vehicle model as the car-to-car script so the crash
    # characteristics stay comparable between the two generators.
    model = 'etk800'

    # The wall is implemented as a procedural cube so we do not need to depend
    # on a specific imported mesh asset. The cube is made very thin along the
    # travel axis and large in width/height so it behaves like a barrier.
    wall = ProceduralCube(
        pos=(0.0, -WALL_DISTANCE, 1.5),
        size=(18.0, 0.4, 3.0),
        rot_quat=(0, 0, 0.707, 0.707),
        name='concrete_wall',
    )
    scenario.add_procedural_mesh(wall)

    # Keep the vehicle at the origin and let it drive forward into the wall.
    # In the current setup this is simpler than trying to manually rotate the
    # car, and it makes the script easier for students to tweak.
    vehicle = Vehicle('vA', model=model, licence='A')
    scenario.add_vehicle(vehicle, pos=(0.0, 0.0, 0.0), rot_quat=(0, 0, 0, 1))

    return scenario, (vehicle,)


def setup_scenario(scenario, vehicles, bng):
    for vehicle in vehicles:
        vehicle.ai_set_mode('disabled')


def step_scenario(scenario, vehicles, bng, throttle_strength):
    vehicle = vehicles[0]  # Only one vehicle in this scenario

    # Keep re-applying throttle so the car continues driving toward the wall.
    vehicle.control(throttle=throttle_strength, steering=0.0)
