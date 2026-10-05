# The browser lane's sign-in door for the survey admin panel
# (e2e/survey_flow.spec.js). Signs the visitor in as the lab's admin, creating
# that row on first use. Drawn at /survey_lab/sign_in, outside /lab, because
# e2e_lab_isolation_test visits every /lab route in a process with no users table.
class SurveyLabSessionsController < ActionController::Base
  def create
    admin = User.find_or_create_by!(email: "admin@lab.test") { |u| u.role = "admin"; u.username = "lab-admin" }
    session[Studio.session_key] = admin.id
    redirect_to params[:to].to_s.start_with?("/") ? params[:to].to_s : "/"
  end
end
