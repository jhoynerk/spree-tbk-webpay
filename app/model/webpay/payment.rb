require 'rest_client'

module TBK
  module Webpay
    class Payment
      # Public: Loads the configuration file tbk-webpay.yml
      # If it's a rails application it will take the file from the config/ directory
      #
      # env - Environment.
      #
      # Returns a Config object.
      def initialize env = nil
        @@config ||= TBK::Webpay::Config.new(env)
      end

      # Public: Initial communication from the application to Webpay servers
      #
      # tbk_total_price - integer - Total amount of the purchase. Last two digits are considered decimals.
      # tbk_order_id - integer - The purchase order id.
      # session_id - integer - The user session id.
      #
      # Returns a REST response to be rendered by the application
      def pay tbk_total_price, order_id, session_id, success_url, failure_url
        tbk_params = {
          'TBK_TIPO_TRANSACCION' => 'TR_NORMAL',
          'TBK_MONTO' => tbk_total_price,
          'TBK_ORDEN_COMPRA' => order_id,
          'TBK_ID_SESION' => session_id,
          'TBK_URL_FRACASO' => failure_url,
          'TBK_URL_EXITO' => success_url
        }

        cgi_url = "#{@@config.tbk_webpay_cgi_base_url}/tbk_bp_pago.cgi"

        tbk_string_params = ""

        tbk_params.each do |key, value|
          tbk_string_params += "#{key}=#{value}&"
        end


        result = RestClient.post cgi_url, tbk_string_params
      end

      # Public: Confirmation callback executed from Webpay servers.
      # Checks Webpay transactions workflow.
      #
      # Returns a string redered as text.
      def confirmation params
        payment = Spree::Payment.find_by(webpay_trx_id: params[:TBK_ID_SESION])
        file_path = "#{@@config.tbk_webpay_tbk_root_path}/log/MAC01Normal#{params[:TBK_ID_SESION]}.txt"
        tbk_mac_path = "#{@@config.tbk_webpay_tbk_root_path}/tbk_check_mac.cgi"
        mac_string = ""
        params.except(:controller, :action, :current_store_id).each do |key, value|
          mac_string += "#{key}=#{value}&" if key != :controller or key != :action or key != :current_store_id
        end

        mac_string.chop!
        File.open file_path, 'w+' do |file|
            file.write(mac_string)
        end

        check_mac = system(tbk_mac_path.to_s, file_path.to_s)

        accepted = true
        unless check_mac
          accepted = false
          Rails.logger.info file_path
          Rails.logger.info tbk_mac_path
          Rails.logger.info mac_string
          Rails.logger.info "Failed check mac"
        end

        # the confirmation is invalid if order_id is unknown
        if not order_exists? params[:TBK_ORDEN_COMPRA], params[:TBK_ID_SESION]
          accepted = false
          Rails.logger.info "Invalid order_id"
        end

        # double payment
        if order_paid? params[:TBK_ORDEN_COMPRA]
          accepted = false
          Rails.logger.info "Double Payment Order #{params[:TBK_ORDEN_COMPRA]}"
        end

        # wrong amount
        if not order_right_amount? params[:TBK_ORDEN_COMPRA], params[:TBK_MONTO]
          accepted = false
          Rails.logger.info "Wrong amount"
        end

        if accepted
          if params[:TBK_RESPUESTA] == "0"
            order = payment.order
            begin
              payment.capture!
              order.next! unless order.completed?
            rescue Spree::Core::GatewayError => error
              Rails.logger.error error
            end
          end
          return "ACEPTADO"
        else
          unless ['processing', 'failed', 'invalid'].include?(payment.state)
            begin
              payment.started_processing!
              payment.failure!
            rescue Spree::Core::GatewayError => error
              Rails.logger.error error
            end            
          end
          return "RECHAZADO"
        end
      end

      private

      # Private: Checks if an order exists and is ready for payment.
      #
      # order_id - integer - The purchase order id.
      #
      # Returns a boolean indicating if the order exists and is ready for payment.
      def order_exists?(order_id, session_id)
        order = Spree::Order.find_by_number(order_id)
        if order.blank?
          return false
        else
          return true
        end
      end

      # Private: Checks if an order is already paid.
      #
      # order_id - integer - The purchase order id.
      #
      # Returns a boolean indicating if the order is already paid.
      def order_paid? order_id
        order = Spree::Order.find_by_number(order_id)
        return order.paid?
      end

      # Private: Checks if an order has the same amount given by Webpay.
      #
      # order_id - integer - The purchase order id.
      # tbk_total_amount - The total amount of the purchase order given by Webpay.
      #
      # Returns a boolean indicating if the order has the same total amount given by Webpay.
      def order_right_amount? order_id, tbk_total_amount
        order = Spree::Order.find_by_number(order_id)
        if order.blank?
          return false
        else
          return order.webpay_amount == tbk_total_amount
        end
      end
    end
  end
end