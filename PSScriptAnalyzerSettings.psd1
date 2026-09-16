@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # Внутренние New/Set/Stop-функции вызываются детерминированными командами pipeline; интерактивный ShouldProcess нарушил бы их машинный контракт.
        'PSUseShouldProcessForStateChangingFunctions',
        # Обязательный TaskDirectory является частью единого контракта adapter, а ProjectRoot используется во вложенной функции.
        'PSReviewUnusedParameter'
    )
}
