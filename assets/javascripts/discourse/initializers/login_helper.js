import { default as EmailLoginController } from "discourse/controllers/email-login";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DiscourseURL from "discourse/lib/url";

export default {
  name: "login-helper",

  initialize() {
    EmailLoginController.reopen({
      actions: {
        finishLogin() {
          let data = {
            second_factor_method: this.secondFactorMethod,
            timezone: moment.tz.guess(),
          };
          if (this.securityKeyCredential) {
            data.second_factor_token = this.securityKeyCredential;
          } else {
            data.second_factor_token = this.secondFactorToken;
          }

          ajax({
            url: `/session/email-login/${this.model.token}`,
            type: "POST",
            data,
          })
          .then((result) => {
              if (result.success) {
              // This is the only change from the original code
              let destination = result.destination_url || "/";

              const safeMode = new URL(
                  this.router.currentURL,
                  window.location.origin
              ).searchParams.get("safe_mode");

              if (safeMode) {
                  const params = new URLSearchParams();
                  params.set("safe_mode", safeMode);
                  destination += `?${params.toString()}`;
              }

              DiscourseURL.redirectTo(destination);
              } else {
              this.set("model.error", result.error);
              }
          })
          .catch(popupAjaxError);
        },
      },
    });
  },
};
