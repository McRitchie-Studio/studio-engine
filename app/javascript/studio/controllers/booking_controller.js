// booking: the booking frame and the booking popup, on the engine's Stimulus
// application (studio/stimulus, which reads data-studio-controller and
// registers this controller lazily). It sits on the frame's wrapper
// (studio/booking/_frame) and on the popup's dialog (studio/booking/_popup):
//
//   <div class="booking-frame" data-booking-wrap data-studio-booking
//        data-studio-controller="booking">
//   <dialog class="booking-popup" data-booking-dialog data-studio-booking
//           data-studio-controller="booking">
//
// The behaviour is studio/booking, installed once per document however many of
// these connect. Until it is installed a booking link is an ordinary link to
// the booking page.
import { Controller } from "@hotwired/stimulus"
import { installBookingFrames, installBookingPopup, armBookingFramesAfterLoad } from "studio/booking"

export default class extends Controller {
  connect() {
    const first = installBookingFrames(window, document)
    installBookingPopup(window, document)
    // A frame that arrives after the install (a stream, a second wrapper).
    if (!first) armBookingFramesAfterLoad(window, document)
  }
}
