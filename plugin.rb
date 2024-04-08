# name: discourse-login-helper
# about: shorten process of loging in by email
# version: 0.0.1
# authors: Thomas Kalka
# url: https://github.com/thoka/discourse-login-helper
# frozen_string_literal: true

after_initialize do
  enabled_site_setting :loginhelper_enabled

  # p "⚠ discourse-login-helper running ..."
  # if username is provided in url, we redirect to login page directly providing the username in cookies

  module LoginHelper
    # add email to links in email notifications
    module BuildEmailHelperExtension
      def build_email(to, opts)
        opts ||= {}
        # puts "🔵 build_email opts=#{opts}"
        opts[:url] += "?" + URI.encode_www_form({ login: to }).to_s if opts.key?(:url)

        super(to, opts)
      end
    end

    # if username is provided in url, we redirect to login page directly on failed topic access
    module ApplicationControllerExtension
      def rescue_discourse_actions(type, status_code, opts = nil)
        path = request.env["PATH_INFO"]

        return super(type, status_code, opts) if type != :invalid_access || current_user.present?

        # puts "🔵 rescue_discourse_actions type=#{type} opts=#{opts}"
        # puts "🔵 PATH_INFO=#{request.env["PATH_INFO"]}"
        # puts "🔵 params #{params}"
        # puts "🔵 current_user #{current_user} present: #{current_user.present?}"

        cookies[:email] = params[:login] if params[:login].present?
        cookies[:email] ||= params[:email] if params[:email].present?
        cookies[:email] ||= params[:username] if params[:username].present?
        cookies[:destination_url] = request.env["PATH_INFO"]

        if cookies[:email].present?
          redirect_to "/login"
        else
          super(type, status_code, opts)
        end
      end
    end
  end

  reloadable_patch do |plugin|
    ApplicationController.prepend LoginHelper::ApplicationControllerExtension
    UserNotifications.class_eval { prepend LoginHelper::BuildEmailHelperExtension }
  end
end
