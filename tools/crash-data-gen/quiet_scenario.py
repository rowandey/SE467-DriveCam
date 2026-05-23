from beamngpy import Scenario, Vehicle

WALL_DISTANCE = 20.0

def create_scenario():
    # A small test map keeps the setup simple and makes it easier to reason
    # about the crash geometry.
    scenario = Scenario('east_coast_usa', 'drivecam_quiet_test')

    # Use the same common vehicle model as the car-to-car script so the crash
    # characteristics stay comparable between the two generators.
    model = 'etk800'

    vehicle = Vehicle('vA', model=model, licence='A')
    scenario.add_vehicle(vehicle, pos=(903.5017700195312, 0.0, 48.0), rot_quat=(0, 0, 0, 1))

    return scenario, (vehicle,)

def setup_scenario(scenario, vehicles, bng):
    # Set the AI mode to 'traffic' so the car will just drive around randomly.
    vehicles[0].ai_set_mode('traffic')


def step_scenario(scenario, vehicles, bng, throttle_strength):
    pass  # Using traffic AI, so nothing special needed
