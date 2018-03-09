module Providers
  class Ovirt::Refresher < InfraManager::Refresher
    def collect_inventory_for_targets(ems, targets)
      targets.map { |target| [target, {}] }
    end

    def parse_targeted_inventory(ems, target, inventory)
      inventory
    end
  end
end
