// survey: the survey stepper, on the engine's Stimulus application
// (studio/stimulus, which reads data-studio-controller and registers this
// controller lazily). It sits on the survey's root (studio/surveys/show):
//
//   <main class="studio-survey" data-studio-survey data-studio-controller="survey"
//         data-answer-base="..." data-resume-index="..." data-csrf="...">
//
// The stepper is studio/survey, which binds a root once. A page restored from
// Turbo's cache is a new element, so it connects and is bound again. Until the
// controller connects, and if it never does, the page is the plain form.
import { Controller } from "@hotwired/stimulus"
import { enhanceSurvey } from "studio/survey"

export default class extends Controller {
  connect() {
    enhanceSurvey(this.element, window, document)
  }
}
