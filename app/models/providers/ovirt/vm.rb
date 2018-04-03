module Providers
  class Ovirt::Vm < Infra::Vm
    POWER_STATES = {
      'up'        => 'on',
      'down'      => 'off',
      'suspended' => 'suspended',
    }.freeze

    def self.calculate_power_state(raw_power_state)
      POWER_STATES[raw_power_state] || super
    end
  end
end
