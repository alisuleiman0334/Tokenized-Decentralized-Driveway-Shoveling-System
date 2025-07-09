;; Health Monitoring Contract
;; Ensures worker safety during strenuous snow clearing activities

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u500))
(define-constant ERR_WORKER_NOT_FOUND (err u501))
(define-constant ERR_INVALID_VITALS (err u502))
(define-constant ERR_SAFETY_VIOLATION (err u503))
(define-constant ERR_EMERGENCY_ACTIVE (err u504))

;; Safety thresholds
(define-constant MAX_WORK_HOURS_PER_DAY u8)
(define-constant MAX_HEART_RATE u180)
(define-constant MIN_BREAK_DURATION u15) ;; 15 minutes
(define-constant MAX_CONSECUTIVE_HOURS u4)

;; Data Variables
(define-data-var next-session-id uint u1)
(define-data-var emergency-contact principal CONTRACT_OWNER)

;; Data Maps
(define-map worker-health-profiles
  { worker: principal }
  {
    age: uint,
    max-safe-heart-rate: uint,
    medical-conditions: (string-ascii 100),
    emergency-contact: principal,
    certified-until: uint,
    total-work-hours: uint
  }
)

(define-map work-sessions
  { session-id: uint }
  {
    worker: principal,
    job-id: uint,
    start-time: uint,
    end-time: (optional uint),
    duration: uint,
    max-heart-rate: uint,
    avg-heart-rate: uint,
    breaks-taken: uint,
    safety-incidents: uint,
    status: (string-ascii 20)
  }
)

(define-map daily-work-logs
  { worker: principal, date: uint }
  {
    total-hours: uint,
    sessions-count: uint,
    breaks-taken: uint,
    safety-score: uint,
    incidents: uint
  }
)

(define-map safety-incidents
  { worker: principal, timestamp: uint }
  {
    incident-type: (string-ascii 50),
    severity: uint,
    description: (string-ascii 200),
    resolved: bool,
    reported-by: principal
  }
)

(define-map emergency-alerts
  { worker: principal, timestamp: uint }
  {
    alert-type: (string-ascii 30),
    vitals: (string-ascii 100),
    location-id: uint,
    status: (string-ascii 20),
    responder: (optional principal)
  }
)

;; Public Functions

;; Register worker health profile
(define-public (register-health-profile
    (age uint)
    (medical-conditions (string-ascii 100))
    (emergency-contact-person principal))
  (let ((max-heart-rate (- u220 age))) ;; Basic formula: 220 - age
    (map-set worker-health-profiles
      { worker: tx-sender }
      {
        age: age,
        max-safe-heart-rate: max-heart-rate,
        medical-conditions: medical-conditions,
        emergency-contact: emergency-contact-person,
        certified-until: (+ block-height u52560), ;; ~1 year in blocks
        total-work-hours: u0
      }
    )
    (print { event: "health-profile-registered", worker: tx-sender, max-heart-rate: max-heart-rate })
    (ok true)
  )
)

;; Start work session
(define-public (start-work-session (job-id uint))
  (match (map-get? worker-health-profiles { worker: tx-sender })
    health-profile
    (let ((session-id (var-get next-session-id))
          (today (/ block-height u144))) ;; Approximate day calculation
      ;; Check daily work hours limit
      (match (map-get? daily-work-logs { worker: tx-sender, date: today })
        daily-log
        (if (>= (get total-hours daily-log) MAX_WORK_HOURS_PER_DAY)
          ERR_SAFETY_VIOLATION
          (create-work-session session-id job-id)
        )
        (create-work-session session-id job-id)
      )
    )
    ERR_WORKER_NOT_FOUND
  )
)

;; End work session
(define-public (end-work-session (session-id uint) (max-heart-rate uint) (avg-heart-rate uint) (breaks-taken uint))
  (match (map-get? work-sessions { session-id: session-id })
    session-data
    (if (is-eq (get worker session-data) tx-sender)
      (let ((duration (- block-height (get start-time session-data)))
            (today (/ block-height u144)))
        (map-set work-sessions
          { session-id: session-id }
          (merge session-data {
            end-time: (some block-height),
            duration: duration,
            max-heart-rate: max-heart-rate,
            avg-heart-rate: avg-heart-rate,
            breaks-taken: breaks-taken,
            status: "completed"
          })
        )
        (update-daily-log tx-sender today duration breaks-taken)
        (update-worker-total-hours tx-sender duration)
        (print { event: "work-session-ended", session-id: session-id, duration: duration })
        (ok true)
      )
      ERR_UNAUTHORIZED
    )
    ERR_WORKER_NOT_FOUND
  )
)

;; Report safety incident
(define-public (report-incident
    (worker principal)
    (incident-type (string-ascii 50))
    (severity uint)
    (description (string-ascii 200)))
  (begin
    (map-set safety-incidents
      { worker: worker, timestamp: block-height }
      {
        incident-type: incident-type,
        severity: severity,
        description: description,
        resolved: false,
        reported-by: tx-sender
      }
    )
    (print { event: "safety-incident-reported", worker: worker, severity: severity })
    (ok true)
  )
)

;; Trigger emergency alert
(define-public (trigger-emergency-alert
    (alert-type (string-ascii 30))
    (vitals (string-ascii 100))
    (location-id uint))
  (begin
    (map-set emergency-alerts
      { worker: tx-sender, timestamp: block-height }
      {
        alert-type: alert-type,
        vitals: vitals,
        location-id: location-id,
        status: "active",
        responder: none
      }
    )
    (print {
      event: "emergency-alert",
      worker: tx-sender,
      alert-type: alert-type,
      location-id: location-id
    })
    (ok true)
  )
)

;; Respond to emergency alert
(define-public (respond-to-emergency (worker principal) (timestamp uint))
  (match (map-get? emergency-alerts { worker: worker, timestamp: timestamp })
    alert-data
    (begin
      (map-set emergency-alerts
        { worker: worker, timestamp: timestamp }
        (merge alert-data {
          status: "responded",
          responder: (some tx-sender)
        })
      )
      (print { event: "emergency-response", worker: worker, responder: tx-sender })
      (ok true)
    )
    ERR_WORKER_NOT_FOUND
  )
)

;; Update health certification
(define-public (update-certification (worker principal) (new-expiry uint))
  (if (is-eq tx-sender CONTRACT_OWNER)
    (match (map-get? worker-health-profiles { worker: worker })
      health-profile
      (begin
        (map-set worker-health-profiles
          { worker: worker }
          (merge health-profile { certified-until: new-expiry })
        )
        (print { event: "certification-updated", worker: worker, expires: new-expiry })
        (ok true)
      )
      ERR_WORKER_NOT_FOUND
    )
    ERR_UNAUTHORIZED
  )
)

;; Private Functions

;; Create new work session
(define-private (create-work-session (session-id uint) (job-id uint))
  (begin
    (map-set work-sessions
      { session-id: session-id }
      {
        worker: tx-sender,
        job-id: job-id,
        start-time: block-height,
        end-time: none,
        duration: u0,
        max-heart-rate: u0,
        avg-heart-rate: u0,
        breaks-taken: u0,
        safety-incidents: u0,
        status: "active"
      }
    )
    (var-set next-session-id (+ session-id u1))
    (print { event: "work-session-started", session-id: session-id, worker: tx-sender })
    (ok session-id)
  )
)

;; Update daily work log
(define-private (update-daily-log (worker principal) (date uint) (duration uint) (breaks uint))
  (match (map-get? daily-work-logs { worker: worker, date: date })
    daily-log
    (map-set daily-work-logs
      { worker: worker, date: date }
      (merge daily-log {
        total-hours: (+ (get total-hours daily-log) duration),
        sessions-count: (+ (get sessions-count daily-log) u1),
        breaks-taken: (+ (get breaks-taken daily-log) breaks)
      })
    )
    (map-set daily-work-logs
      { worker: worker, date: date }
      {
        total-hours: duration,
        sessions-count: u1,
        breaks-taken: breaks,
        safety-score: u100,
        incidents: u0
      }
    )
  )
)

;; Update worker total hours
(define-private (update-worker-total-hours (worker principal) (duration uint))
  (match (map-get? worker-health-profiles { worker: worker })
    health-profile
    (map-set worker-health-profiles
      { worker: worker }
      (merge health-profile {
        total-work-hours: (+ (get total-work-hours health-profile) duration)
      })
    )
    false
  )
)

;; Read-only Functions

;; Get worker health profile
(define-read-only (get-health-profile (worker principal))
  (map-get? worker-health-profiles { worker: worker })
)

;; Get work session details
(define-read-only (get-work-session (session-id uint))
  (map-get? work-sessions { session-id: session-id })
)

;; Get daily work log
(define-read-only (get-daily-log (worker principal) (date uint))
  (map-get? daily-work-logs { worker: worker, date: date })
)

;; Get safety incident
(define-read-only (get-safety-incident (worker principal) (timestamp uint))
  (map-get? safety-incidents { worker: worker, timestamp: timestamp })
)

;; Get emergency alert
(define-read-only (get-emergency-alert (worker principal) (timestamp uint))
  (map-get? emergency-alerts { worker: worker, timestamp: timestamp })
)

;; Check if worker is certified
(define-read-only (is-worker-certified (worker principal))
  (match (map-get? worker-health-profiles { worker: worker })
    health-profile
    (ok (> (get certified-until health-profile) block-height))
    (ok false)
  )
)

;; Get safety thresholds
(define-read-only (get-safety-thresholds)
  {
    max-work-hours-per-day: MAX_WORK_HOURS_PER_DAY,
    max-heart-rate: MAX_HEART_RATE,
    min-break-duration: MIN_BREAK_DURATION,
    max-consecutive-hours: MAX_CONSECUTIVE_HOURS
  }
)
