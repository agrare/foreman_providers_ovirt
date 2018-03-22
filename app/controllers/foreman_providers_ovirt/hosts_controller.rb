module ForemanProvidersOvirt
  # Example: Plugin's HostsController inherits from Foreman's HostsController
  class HostsController < ::HostsController
    # change layout if needed
    # layout 'foreman_providers_ovirt/layouts/new_layout'

    def new_action
      # automatically renders view/foreman_providers_ovirt/hosts/new_action
    end
  end
end
