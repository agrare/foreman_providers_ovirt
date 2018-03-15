module Providers
  class Ovirt::Manager < ExtManagementSystem
    include Infra::Associations
    include ApiIntegration

  end
end
