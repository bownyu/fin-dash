package com.findash.fin_dash

import java.math.BigDecimal

data class PaymentMatch(val amountCents: Long?, val kind: String, val merchant: String, val reviewReason: String)

/** Conservative local rules. Community examples are fixtures, not a platform contract. */
object PaymentRules {
    const val VERSION = 2
    val packages = setOf("com.tencent.mm", "com.eg.android.AlipayGphone")
    // Capture the whole numeric token before validating it; never read a valid
    // suffix of an invalid amount such as 1,23.45 or -10.00 as a payment.
    private val amount = Regex("[¥￥]\\s*([-+]?\\s*[0-9][0-9,.]*)|(?<![0-9,.+\\-])([-+]?\\s*[0-9][0-9,.]*)\\s*元")
    private val validAmount = Regex("(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\\.[0-9]{1,2})?")
    private val blocked = Regex("验证码|待付款|待支付|未支付|付款失败|支付失败|扣款失败|转账失败|还款失败|退款失败|交易关闭|已取消|请付款|领取红包|优惠券待领取|还款提醒|待还款|待扣款|退款申请|处理中|限时活动|转账享优惠")
    private val signal = Regex("成功付款|付款成功|支付成功|成功收款|收款成功|收款到账|收到.*(?:转账|退款)|退款|还款|转账|扣款|支出|向.+付款|支付[¥￥]")

    fun parse(packageName: String, title: String, text: String): PaymentMatch? {
        if (packageName !in packages) return null
        val full = "$title $text".trim()
        if (blocked.containsMatchIn(full)) return null
        if (packageName == "com.tencent.mm" &&
            !Regex("^(微信支付|微信支付凭证|微信支付收款|微信收款助手|收款助手)([：:（(].*)?$").matches(title.trim())) return null
        if (packageName == "com.eg.android.AlipayGphone" &&
            !Regex("^(支付宝|支付宝支付|付款成功|支付成功|收款到账|交易提醒|退款通知|转账到账)([：:（(].*)?$").matches(title.trim())) return null
        if (!signal.containsMatchIn(full)) return null
        val parsed = amount.findAll(full).map { m ->
            val raw = m.groupValues[1].ifEmpty { m.groupValues[2] }.trim()
            if (!validAmount.matches(raw)) return@map null
            try { BigDecimal(raw.replace(",", "")).movePointRight(2).longValueExact().takeIf { it in 1..999_999_999_999L } }
            catch (_: ArithmeticException) { null }
            catch (_: NumberFormatException) { null }
        }.toList()
        val invalidAmount = parsed.any { it == null }
        val values = parsed.filterNotNull().toSet()
        val kind = when {
            full.contains("退款") -> "refund"
            full.contains("还款") -> "repayment"
            full.contains("转账") -> "transfer"
            Regex("收款|到账|向你付款|向您付款").containsMatchIn(full) -> "income"
            Regex("付款成功|成功付款|支付成功|支出|扣款|向.+付款|支付[¥￥]").containsMatchIn(full) -> "expense"
            else -> "unknown"
        }
        val merchant = Regex("向\\s*(?!你|您)(.+?)\\s*付款").find(text)?.groupValues?.get(1)
            ?: Regex("[（(]([^（）()]{2,60})[）)]").find(text)?.groupValues?.get(1) ?: ""
        val reason = when {
            invalidAmount -> "通知金额格式无效或超出范围，请手动核对"
            values.size > 1 -> "通知包含多个金额，请核对实际交易金额"
            values.isEmpty() -> "通知未提供明确金额，请手动补全"
            kind == "refund" -> "退款需关联原交易核对，当前不自动计入收入"
            kind == "transfer" || kind == "repayment" -> "请核对是否为本人账户间转账，并选择实际账户"
            kind == "unknown" -> "收支方向不明确，请核对"
            else -> "请核对金额、交易时间及实际扣款或收款账户"
        }
        return PaymentMatch(if (invalidAmount) null else values.singleOrNull(), kind, merchant.take(100), reason)
    }
}
