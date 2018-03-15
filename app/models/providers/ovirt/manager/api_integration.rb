# require 'openssl'
# require 'resolv'

module Providers::Ovirt::Manager::ApiIntegration
  extend ActiveSupport::Concern

  require 'ovirtsdk4'
  require 'ovirt'

  def supported_features
    @supported_features ||= supported_api_versions.collect { |version| self.class.api_features[version.to_s] }.flatten.uniq
  end

  def use_graph_refresh?
    false
  end

  def connect(options = {})
    # Prepare the options to call the method that creates the actual connection:
    connect_options = {
      :id         => id,
      :scheme     => options[:scheme] || 'https',
      :server     => options[:ip] || ipaddress || hostname,
      :port       => options[:port] || port,
      :path       => options[:path] || '/ovirt-engine/api',
      :username   => options[:user] || authentication_userid(options[:auth_type]),
      :password   => options[:pass] || authentication_password(options[:auth_type]),
      :service    => options[:service] || "Service",
      :verify_ssl => default_endpoint.verify_ssl,
      :ca_certs   => default_endpoint.certificate_authority
    }

    # Create the underlying connection according to the version of the oVirt API requested by
    # the caller:
    version = '3'
    connect_method = "raw_connect_v#{version}".to_sym
    connection = self.class.public_send(connect_method, connect_options)

    # Copy the API path to the endpoints table:
    default_endpoint.path = connect_options[:path]

    connection
  end

  def supports_port?
    true
  end

  def supported_auth_types
    %w(default metrics)
  end

  def supports_authentication?(authtype)
    supported_auth_types.include?(authtype.to_s)
  end

  def rhevm_service
    @rhevm_service ||= connect(:service => "Service")
  end

  def rhevm_inventory(opts = {})
    connect_options = { :service => "Inventory" }
    connect_options[:version] = 3 if opts[:force_v3]
    @rhevm_inventory ||= connect(connect_options)
  end

  def with_provider_connection(options = {})
    raise "no block given" unless block_given?
    _log.info("Connecting through #{self.class.name}: [#{name}]")
    begin
      connection = connect(options)
      yield connection
    ensure
      begin
        self.class.disconnect(connection)
      rescue => error
        _log.error("Error while disconnecting #{error}")
        nil
      end
    end
  end

  def verify_credentials_for_rhevm(options = {})
    with_provider_connection(options) { |connection| connection.test(true) }
  rescue Exception => e
    self.class.handle_credentials_verification_error(e)
  end

  def rhevm_metrics_connect_options(options = {})
    metrics_hostname = connection_configuration_by_role('metrics')
                       .try(:endpoint)
                       .try(:hostname)
    server   = options[:hostname] || metrics_hostname || hostname
    username = options[:user] || authentication_userid(:metrics)
    password = options[:pass] || authentication_password(:metrics)
    database = options[:database] || history_database_name

    {
      :host     => server,
      :database => database,
      :username => username,
      :password => password
    }
  end


  def authentications_to_validate
    at = [:default]
    at << :metrics if has_authentication_type?(:metrics)
    at
  end

  def verify_credentials(auth_type = nil, options = {})
    options[:skip_supported_api_validation] = true
    auth_type ||= 'default'
    case auth_type.to_s
    when 'default' then verify_credentials_for_rhevm(options)
    when 'metrics' then verify_credentials_for_rhevm_metrics(options)
    else;          raise "Invalid Authentication Type: #{auth_type.inspect}"
    end
  end


  def use_ovirt_sdk?
    true
  end

  class_methods do
    def disconnect(connection)
      if connection.respond_to?(:disconnect)
        connection.disconnect
      end
    end

    def api3_supported_features
      []
    end

    def api4_supported_features
      [
        :migrate,
        :quick_stats,
        :reconfigure_disks,
        :snapshots,
        :publish
      ]
    end

    def api_features
      { "3" => api3_supported_features, "4" => api4_supported_features }
    end


    def rethrow_as_a_miq_error(ovirt_sdk_4_error)
      case ovirt_sdk_4_error.message
      when /The username or password is incorrect/
        raise MiqException::MiqInvalidCredentialsError, "Incorrect user name or password."
      when /Couldn't connect to server/, /Couldn't resolve host name/
        raise MiqException::MiqUnreachableError, $ERROR_INFO
      else
        _log.error("Error while verifying credentials #{$ERROR_INFO}")
        raise MiqException::MiqEVMLoginError, $ERROR_INFO
      end
    end

    def handle_credentials_verification_error(e)
      case e
      when SocketError, Errno::EHOSTUNREACH, Errno::ENETUNREACH
        _log.warn($ERROR_INFO)
        raise MiqException::MiqUnreachableError, $ERROR_INFO
      when MiqException::MiqUnreachableError
        raise e
      when RestClient::Unauthorized
        raise MiqException::MiqInvalidCredentialsError, "Incorrect user name or password."
      when OvirtSDK4::Error
        rethrow_as_a_miq_error(e)
      else
        _log.error("Error while verifying credentials #{$ERROR_INFO}")
        raise MiqException::MiqEVMLoginError, $ERROR_INFO
      end
    end

    #
    # Checks the API connection details.
    #
    # @api private
    #
    def check_connect_api(opts = {})
      # Get options and assign default values:
      username = opts[:username]
      password = opts[:password]
      server = opts[:server]
      port = opts[:port] || 443
      verify_ssl = opts[:verify_ssl] || 1
      ca_certs = opts[:ca_certs]

      # Decrypt the password:
      password = MiqPassword.try_decrypt(password)

      # Starting with version 4 of oVirt authentication doesn't work when using directly the IP address, it requires
      # the fully qualified host name, so if we received an IP address we try to convert it into the corresponding
      # host name:
      resolved = server
      if resolve_ip_addresses?
        resolved = resolve_ip_address(server)
        if resolved != server
          _log.info("IP address '#{server}' has been resolved to host name '#{resolved}'.")
        end
      end

      # Build the options that will be used to call the methods that create the connection with specific versions
      # of the API:
      opts = {
        :username   => username,
        :password   => password,
        :server     => resolved,
        :port       => port,
        :verify_ssl => verify_ssl,
        :ca_certs   => ca_certs,
        :service    => 'Inventory' # This is needed only for version 3 of the API.
      }

      # Try to verify the details using version 4 of the API. If this succeeds or fails with an authentication
      # exception, then we don't need to do anything else. Note that the connection should not be closed, because
      # that is handled by the `ConnectionManager` class.
      begin
        connection = raw_connect_v4(opts)
        connection.test(:raise_exception => true)
        return true
      rescue OvirtSDK4::Error => error
        raise error if /error.*sso/i =~ error.message
      end

      # Try to verify the details using version 3 of the API.
      begin
        connection = raw_connect_v3(opts)
        connection.api
      ensure
        disconnect(connection)
      end
      true
    end


    # Connect to the engine using version 3 of the API and the `ovirt` gem.
    def raw_connect_v3(options = {})
      require 'ovirt'
      require 'foreman_providers_ovirt/legacy/inventory'
      Ovirt.logger = $rhevm_log

      # If 'ca_certs' is an empty string then the 'ovirt' gem will trust nothing, but we want it to trust the system CA
      # certificates. To get that behaviour we need to pass 'nil' instead of the empty string.
      ca_certs = options[:ca_certs]
      ca_certs = nil if ca_certs.blank?

      params = {
        :server     => options[:server],
        :port       => options[:port].presence && options[:port].to_i,
        :path       => '/ovirt-engine/api',
        :username   => options[:username],
        :password   => options[:password],
        :verify_ssl => options[:verify_ssl],
        :ca_certs   => ca_certs
      }

      read_timeout, open_timeout = nil,nil #ems_timeouts(:ems_redhat, options[:service])
      params[:timeout]      = read_timeout if read_timeout
      params[:open_timeout] = open_timeout if open_timeout
      conn = ForemanProvidersOvirt::Legacy::Inventory.new(params)
    end


    # Calculates an "ems_ref" from the "href" attribute provided by the oVirt REST API, removing the
    # "/ovirt-engine/" prefix, as for historic reasons the "ems_ref" stored in the database does not
    # contain it, it only contains the "/api" prefix which was used by older versions of the engine.
    def make_ems_ref(href)
      href && href.sub(%r{^/ovirt-engine/}, '/')
    end

    def extract_ems_ref_id(href)
      href && href.split("/").last
    end
  end
end
