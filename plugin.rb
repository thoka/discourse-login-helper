# name: discourse-login-helper
# about: shorten process of loging in by email
# version: 0.0.0
# authors: Thomas Kalka
# url: https://github.com/thoka/discourse-login-helper
# frozen_string_literal: true

after_initialize do
  # enabled_site_setting :login_helper_enabled

  # p "⚠ discourse-login-helper running ..."
  # if username is provided in url, we redirect to login page directly providing the username in cookies

  module LoginHelper
    # add email to links in email notifications
    module BuildEmailHelperExtension
      def build_email(to, opts)
        opts ||= {}
        puts "🔵 build_email opts=#{opts}"
        opts[:url] += "?" + URI.encode_www_form({ login: to }).to_s if opts.key?(:url)
        super(to, opts)
      end
    end

    # if username is provided in url, we redirect to login page directly
    module ApplicationControllerExtension
      def rescue_discourse_actions(type, status_code, opts = nil)
        path = request.env["PATH_INFO"]
        return super(type, status_code, opts) unless path.start_with? "/t/"

        puts "🔵 rescue_discourse_actions type=#{type} opts=#{opts}"
        puts "🔵 PATH_INFO=#{request.env["PATH_INFO"]}"
        puts "🔵 params #{params}"

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
