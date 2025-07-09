;; Payment Processing Contract
;; Handles service fees and tip transactions for snow clearing services

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u400))
(define-constant ERR_INSUFFICIENT_BALANCE (err u401))
(define-constant ERR_PAYMENT_NOT_FOUND (err u402))
(define-constant ERR_INVALID_AMOUNT (err u403))
(define-constant ERR_PAYMENT_ALREADY_PROCESSED (err u404))

;; Token name and symbol
(define-constant TOKEN_NAME "SHOVEL")
(define-constant TOKEN_SYMBOL "SHV")
(define-constant TOKEN_DECIMALS u6)

;; Data Variables
(define-data-var token-total-supply uint u1000000000000) ;; 1M tokens with 6 decimals
(define-data-var next-payment-id uint u1)
(define-data-var platform-fee-rate uint u250) ;; 2.5% (250/10000)

;; Data Maps
(define-map token-balances
  { owner: principal }
  { balance: uint }
)

(define-map payments
  { payment-id: uint }
  {
    payer: principal,
    recipient: principal,
    amount: uint,
    tip-amount: uint,
    job-id: uint,
    status: (string-ascii 20),
    created-at: uint,
    processed-at: (optional uint),
    platform-fee: uint
  }
)

(define-map escrow-payments
  { job-id: uint }
  {
    payer: principal,
    amount: uint,
    tip-amount: uint,
    created-at: uint,
    released: bool
  }
)

(define-map user-stats
  { user: principal }
  {
    total-paid: uint,
    total-earned: uint,
    total-tips-given: uint,
    total-tips-received: uint,
    payment-count: uint
  }
)

;; Initialize contract owner balance
(map-set token-balances
  { owner: CONTRACT_OWNER }
  { balance: (var-get token-total-supply) }
)

;; Public Functions

;; Transfer tokens
(define-public (transfer (amount uint) (recipient principal))
  (let ((sender-balance (get-balance tx-sender)))
    (if (>= sender-balance amount)
      (begin
        (map-set token-balances
          { owner: tx-sender }
          { balance: (- sender-balance amount) }
        )
        (map-set token-balances
          { owner: recipient }
          { balance: (+ (get-balance recipient) amount) }
        )
        (print { event: "token-transfer", from: tx-sender, to: recipient, amount: amount })
        (ok true)
      )
      ERR_INSUFFICIENT_BALANCE
    )
  )
)

;; Create escrow payment for job
(define-public (create-escrow-payment (job-id uint) (amount uint) (tip-amount uint))
  (let ((total-amount (+ amount tip-amount))
        (sender-balance (get-balance tx-sender)))
    (if (>= sender-balance total-amount)
      (begin
        (map-set token-balances
          { owner: tx-sender }
          { balance: (- sender-balance total-amount) }
        )
        (map-set escrow-payments
          { job-id: job-id }
          {
            payer: tx-sender,
            amount: amount,
            tip-amount: tip-amount,
            created-at: block-height,
            released: false
          }
        )
        (print { event: "escrow-created", job-id: job-id, amount: total-amount, payer: tx-sender })
        (ok true)
      )
      ERR_INSUFFICIENT_BALANCE
    )
  )
)

;; Release escrow payment to worker
(define-public (release-escrow-payment (job-id uint) (worker principal))
  (match (map-get? escrow-payments { job-id: job-id })
    escrow-data
    (if (and
          (is-eq (get payer escrow-data) tx-sender)
          (not (get released escrow-data)))
      (let ((payment-id (var-get next-payment-id))
            (base-amount (get amount escrow-data))
            (tip-amount (get tip-amount escrow-data))
            (platform-fee (/ (* base-amount (var-get platform-fee-rate)) u10000))
            (worker-amount (- (+ base-amount tip-amount) platform-fee)))
        (map-set payments
          { payment-id: payment-id }
          {
            payer: tx-sender,
            recipient: worker,
            amount: base-amount,
            tip-amount: tip-amount,
            job-id: job-id,
            status: "completed",
            created-at: (get created-at escrow-data),
            processed-at: (some block-height),
            platform-fee: platform-fee
          }
        )
        (map-set escrow-payments
          { job-id: job-id }
          (merge escrow-data { released: true })
        )
        (map-set token-balances
          { owner: worker }
          { balance: (+ (get-balance worker) worker-amount) }
        )
        (map-set token-balances
          { owner: CONTRACT_OWNER }
          { balance: (+ (get-balance CONTRACT_OWNER) platform-fee) }
        )
        (update-user-stats tx-sender worker base-amount tip-amount)
        (var-set next-payment-id (+ payment-id u1))
        (print {
          event: "payment-processed",
          payment-id: payment-id,
          worker: worker,
          amount: worker-amount,
          platform-fee: platform-fee
        })
        (ok payment-id)
      )
      ERR_UNAUTHORIZED
    )
    ERR_PAYMENT_NOT_FOUND
  )
)

;; Direct payment (without escrow)
(define-public (make-payment (recipient principal) (amount uint) (tip-amount uint) (job-id uint))
  (let ((total-amount (+ amount tip-amount))
        (platform-fee (/ (* amount (var-get platform-fee-rate)) u10000))
        (recipient-amount (- total-amount platform-fee))
        (sender-balance (get-balance tx-sender)))
    (if (>= sender-balance total-amount)
      (let ((payment-id (var-get next-payment-id)))
        (map-set payments
          { payment-id: payment-id }
          {
            payer: tx-sender,
            recipient: recipient,
            amount: amount,
            tip-amount: tip-amount,
            job-id: job-id,
            status: "completed",
            created-at: block-height,
            processed-at: (some block-height),
            platform-fee: platform-fee
          }
        )
        (map-set token-balances
          { owner: tx-sender }
          { balance: (- sender-balance total-amount) }
        )
        (map-set token-balances
          { owner: recipient }
          { balance: (+ (get-balance recipient) recipient-amount) }
        )
        (map-set token-balances
          { owner: CONTRACT_OWNER }
          { balance: (+ (get-balance CONTRACT_OWNER) platform-fee) }
        )
        (update-user-stats tx-sender recipient amount tip-amount)
        (var-set next-payment-id (+ payment-id u1))
        (print { event: "direct-payment", payment-id: payment-id, amount: recipient-amount })
        (ok payment-id)
      )
      ERR_INSUFFICIENT_BALANCE
    )
  )
)

;; Mint tokens (admin only)
(define-public (mint-tokens (recipient principal) (amount uint))
  (if (is-eq tx-sender CONTRACT_OWNER)
    (begin
      (map-set token-balances
        { owner: recipient }
        { balance: (+ (get-balance recipient) amount) }
      )
      (var-set token-total-supply (+ (var-get token-total-supply) amount))
      (print { event: "tokens-minted", recipient: recipient, amount: amount })
      (ok true)
    )
    ERR_UNAUTHORIZED
  )
)

;; Private Functions

;; Update user statistics
(define-private (update-user-stats (payer principal) (recipient principal) (amount uint) (tip-amount uint))
  (begin
    ;; Update payer stats
    (match (map-get? user-stats { user: payer })
      payer-stats
      (map-set user-stats
        { user: payer }
        (merge payer-stats {
          total-paid: (+ (get total-paid payer-stats) amount),
          total-tips-given: (+ (get total-tips-given payer-stats) tip-amount),
          payment-count: (+ (get payment-count payer-stats) u1)
        })
      )
      (map-set user-stats
        { user: payer }
        {
          total-paid: amount,
          total-earned: u0,
          total-tips-given: tip-amount,
          total-tips-received: u0,
          payment-count: u1
        }
      )
    )
    ;; Update recipient stats
    (match (map-get? user-stats { user: recipient })
      recipient-stats
      (map-set user-stats
        { user: recipient }
        (merge recipient-stats {
          total-earned: (+ (get total-earned recipient-stats) amount),
          total-tips-received: (+ (get total-tips-received recipient-stats) tip-amount)
        })
      )
      (map-set user-stats
        { user: recipient }
        {
          total-paid: u0,
          total-earned: amount,
          total-tips-given: u0,
          total-tips-received: tip-amount,
          payment-count: u0
        }
      )
    )
  )
)

;; Read-only Functions

;; Get token balance
(define-read-only (get-balance (owner principal))
  (default-to u0 (get balance (map-get? token-balances { owner: owner })))
)

;; Get payment details
(define-read-only (get-payment (payment-id uint))
  (map-get? payments { payment-id: payment-id })
)

;; Get escrow payment details
(define-read-only (get-escrow-payment (job-id uint))
  (map-get? escrow-payments { job-id: job-id })
)

;; Get user statistics
(define-read-only (get-user-stats (user principal))
  (map-get? user-stats { user: user })
)

;; Get token info
(define-read-only (get-token-info)
  {
    name: TOKEN_NAME,
    symbol: TOKEN_SYMBOL,
    decimals: TOKEN_DECIMALS,
    total-supply: (var-get token-total-supply)
  }
)

;; Get platform fee rate
(define-read-only (get-platform-fee-rate)
  (var-get platform-fee-rate)
)
