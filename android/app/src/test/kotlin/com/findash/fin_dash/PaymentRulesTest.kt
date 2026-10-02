package com.findash.fin_dash

import org.junit.Assert.*
import org.junit.Test

class PaymentRulesTest {
    @Test fun malformedAmountsNeverBecomePartialPositiveAmounts() {
        listOf("￥1,23.45", "-10.00元", "￥12.345", "￥0.00", "￥999999999999.99", "￥10.00 原价￥1,23.45").forEach { text ->
            val result = PaymentRules.parse("com.eg.android.AlipayGphone", "付款成功", text)!!
            assertNull(text, result.amountCents)
            assertTrue(result.reviewReason.contains("格式无效"))
        }
    }
    @Test fun remindersPendingOperationsAndMarketingAreRejected() {
        listOf("还款提醒：待还款100元", "转账享优惠，领取100元", "退款申请处理中10元", "扣款失败10元", "转账失败10元").forEach { text ->
            assertNull(text, PaymentRules.parse("com.eg.android.AlipayGphone", "支付宝", text))
        }
    }
    @Test fun parsesExactCentsAndMerchant() {
        val result = PaymentRules.parse("com.tencent.mm", "微信支付", "支付￥25.01（肯德基）")!!
        assertEquals(2501L, result.amountCents)
        assertEquals("expense", result.kind)
        assertEquals("肯德基", result.merchant)
    }
    @Test fun rejectsOrdinaryChatAndUnknownApps() {
        assertNull(PaymentRules.parse("com.tencent.mm", "张三", "已向商店付款100.00元"))
        assertNull(PaymentRules.parse("fake.app", "微信支付", "支付￥25.00"))
        assertNull(PaymentRules.parse("com.eg.android.AlipayGphone", "优惠活动", "支付￥25.00"))
    }
    @Test fun failedPaymentsAndOtpsAreNotTransactions() {
        assertNull(PaymentRules.parse("com.eg.android.AlipayGphone", "支付宝", "支付失败￥25.00"))
        assertNull(PaymentRules.parse("com.eg.android.AlipayGphone", "支付宝", "付款成功验证码123456，25.00元"))
    }
    @Test fun missingAndAmbiguousAmountsStayReviewable() {
        val missing = PaymentRules.parse("com.eg.android.AlipayGphone", "支付宝", "收到一笔转账，点击查看详情")!!
        assertNull(missing.amountCents)
        val many = PaymentRules.parse("com.tencent.mm", "微信支付", "支付￥10.00 原价￥12.00")!!
        assertNull(many.amountCents)
        assertTrue(many.reviewReason.contains("多个金额"))
    }
    @Test fun repeatedExpandedTextDoesNotCreateAnAmbiguousAmount() {
        assertEquals(1000L, PaymentRules.parse("com.tencent.mm", "微信支付", "支付￥10.00\n支付￥10.00（商店）")!!.amountCents)
    }
    @Test fun refundAndRepaymentStayDistinctFromIncome() {
        assertEquals("refund", PaymentRules.parse("com.eg.android.AlipayGphone", "支付宝", "收到退款 10.00 元")!!.kind)
        assertEquals("repayment", PaymentRules.parse("com.eg.android.AlipayGphone", "支付宝", "还款成功 10.00 元")!!.kind)
    }
    @Test fun transferAndIncomeAreDistinct() {
        assertEquals("transfer", PaymentRules.parse("com.tencent.mm", "微信支付", "收到张三的转账 100.00元")!!.kind)
        assertEquals("income", PaymentRules.parse("com.tencent.mm", "微信支付收款", "微信支付收款到账50.00元")!!.kind)
    }
    @Test fun thousandsSeparatorsAndLeadingCurrencyAreSupported() {
        assertEquals(123456L, PaymentRules.parse("com.eg.android.AlipayGphone", "付款成功", "成功付款￥1,234.56")!!.amountCents)
    }
}
