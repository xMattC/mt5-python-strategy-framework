//+------------------------------------------------------------------+
//|                                             AdjustPosition.mqh   |
//|   Manages stop loss adjustments, trailing stops, and breakevens  |
//|                                                                  |
//|                                  2025 xMattC (github.com/xMattC) |
//+------------------------------------------------------------------+
#property copyright "2025 xMattC (github.com/xMattC)"
#property link      "https://github.com/xMattC"
#property version   "1.00"

#include <Trade/Trade.mqh>
#include <MyLibs/utils/AtrHandleManager.mqh>

// ---------------------------------------------------------------------
// GLOBALS
// ---------------------------------------------------------------------
CTrade trade;
AtrHandleManager atr_manager;

class AdjustPosition {
public:
    void set_breakeven_sl(string symbol, int runner_magic_no, double buffer_points = 5);
    void set_breakeven_if_profit_target_hit(string symbol, int runner_magic_no, double buffer_points = 5);
    void set_fixed_sl(string symbol, int runner_magic_no, double fixed_sl_price);
    void set_trailing_sl(string symbol, int runner_magic_no, double sl_offset_points = 5);
    void trailing_stop_atr(string symbol, int magic_number, ENUM_TIMEFRAMES tf = PERIOD_CURRENT, double activation_mult = 1.0,
                           double trail_mult = 1.0, int atr_period = 14, bool use_bar_close = false);

private:
    void set_breakeven_sl_for_ticket(string symbol, ulong ticket, long order_type, double entry_price,
                                     double current_sl, double current_tp, int digits, double buffer_price, bool remove_tp);
};

// ---------------------------------------------------------------------
// Sets SL to breakeven for all matching runner trades.
// ---------------------------------------------------------------------
void AdjustPosition::set_breakeven_sl(string symbol, int runner_magic_no, double buffer_points) {
    int digits = (int) SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double buffer_price = buffer_points * _Point;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(ticket)) continue;
        if (PositionGetString(POSITION_SYMBOL) != symbol) continue;
        if ((int) PositionGetInteger(POSITION_MAGIC) != runner_magic_no) continue;

        long order_type = PositionGetInteger(POSITION_TYPE);
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl = PositionGetDouble(POSITION_SL);
        double tp = PositionGetDouble(POSITION_TP);

        set_breakeven_sl_for_ticket(symbol, ticket, order_type, entry, sl, tp, digits, buffer_price, false);
    }
}

// ---------------------------------------------------------------------
// Sets SL to breakeven if virtual TP (in comment) was hit.
// ---------------------------------------------------------------------
void AdjustPosition::set_breakeven_if_profit_target_hit(string symbol, int runner_magic_no, double buffer_points) {
    double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    int digits = (int) SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double buffer_price = buffer_points * _Point;
    double price_margin = 50 * _Point;

    bool has_runner = false;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(ticket)) continue;
        if (PositionGetString(POSITION_SYMBOL) != symbol) continue;
        if ((int) PositionGetInteger(POSITION_MAGIC) == runner_magic_no) {
            has_runner = true;
            break;
        }
    }
    if (!has_runner) return;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(ticket)) continue;
        if (PositionGetString(POSITION_SYMBOL) != symbol) continue;
        if ((int) PositionGetInteger(POSITION_MAGIC) != runner_magic_no) continue;

        long order_type = PositionGetInteger(POSITION_TYPE);
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl = PositionGetDouble(POSITION_SL);
        double tp = PositionGetDouble(POSITION_TP);
        string comment = PositionGetString(POSITION_COMMENT);

        double virtual_tp = 0.0;
        if (StringFind(comment, "runner_tp:") == 0) {
            string tp_str = StringSubstr(comment, StringLen("runner_tp:"));
            virtual_tp = StringToDouble(tp_str);
        }

        if (virtual_tp <= 0.0) continue;
        if (tp > 0.0)
            PrintFormat("Warning: Runner trade on %s (ticket %d) has TP set: %.5f", symbol, ticket, tp);

        if (order_type == POSITION_TYPE_BUY && bid < virtual_tp - price_margin) continue;
        if (order_type == POSITION_TYPE_SELL && ask > virtual_tp + price_margin) continue;

        bool tp_hit = (order_type == POSITION_TYPE_BUY && bid >= virtual_tp) ||
                      (order_type == POSITION_TYPE_SELL && ask <= virtual_tp);
        if (!tp_hit) continue;

        double expected_sl = (order_type == POSITION_TYPE_BUY)
                             ? entry + buffer_price
                             : entry - buffer_price;

        if (NormalizeDouble(sl, digits) == NormalizeDouble(expected_sl, digits)) continue;

        set_breakeven_sl_for_ticket(symbol, ticket, order_type, entry, sl, tp, digits, buffer_price, true);
    }
}

// ---------------------------------------------------------------------
// Sets SL for a single trade to breakeven, optionally removes TP.
// ---------------------------------------------------------------------
void AdjustPosition::set_breakeven_sl_for_ticket(string symbol, ulong ticket, long order_type, double entry_price,
                                                 double current_sl, double current_tp, int digits,
                                                 double buffer_price, bool remove_tp) {
    double breakeven_sl = (order_type == POSITION_TYPE_BUY)
                          ? entry_price + buffer_price
                          : entry_price - buffer_price;

    if ((order_type == POSITION_TYPE_BUY && current_sl >= breakeven_sl) ||
        (order_type == POSITION_TYPE_SELL && current_sl <= breakeven_sl)) return;

    MqlTradeRequest request = {};
    MqlTradeResult result;

    request.action = TRADE_ACTION_SLTP;
    request.symbol = symbol;
    request.position = ticket;
    request.sl = NormalizeDouble(breakeven_sl, digits);
    request.tp = remove_tp ? 0.0 : current_tp;
    request.magic = (int) PositionGetInteger(POSITION_MAGIC);

    if (!OrderSend(request, result))
        Print("Failed to adjust runner: ", symbol, ". Error: ", result.retcode);
    else if (remove_tp)
        Print("Runner upgraded to trailing: SL at breakeven, TP removed for ", symbol);
}

// ---------------------------------------------------------------------
// Sets a fixed SL price for all runner trades.
// ---------------------------------------------------------------------
void AdjustPosition::set_fixed_sl(string symbol, int runner_magic_no, double fixed_sl_price) {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(ticket)) continue;
        if (PositionGetString(POSITION_SYMBOL) != symbol) continue;
        if ((int) PositionGetInteger(POSITION_MAGIC) != runner_magic_no) continue;

        double current_sl = PositionGetDouble(POSITION_SL);
        double current_tp = PositionGetDouble(POSITION_TP);
        if (current_sl == fixed_sl_price) continue;

        MqlTradeRequest request = {};
        MqlTradeResult result;

        request.action = TRADE_ACTION_SLTP;
        request.symbol = symbol;
        request.position = ticket;
        request.sl = fixed_sl_price;
        request.tp = current_tp;
        request.magic = runner_magic_no;

        if (!OrderSend(request, result))
            Print("Failed to set fixed SL for runner on ", symbol, ". Error: ", result.retcode);
    }
}

// ---------------------------------------------------------------------
// Applies a fixed-point trailing stop to runner trades.
// ---------------------------------------------------------------------
void AdjustPosition::set_trailing_sl(string symbol, int runner_magic_no, double sl_offset_points) {
    int digits = (int) SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double offset = sl_offset_points * _Point;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(ticket)) continue;
        if (PositionGetString(POSITION_SYMBOL) != symbol) continue;
        if ((int) PositionGetInteger(POSITION_MAGIC) != runner_magic_no) continue;

        long type = PositionGetInteger(POSITION_TYPE);
        double current_sl = PositionGetDouble(POSITION_SL);
        double current_tp = PositionGetDouble(POSITION_TP);
        double price = (type == POSITION_TYPE_BUY)
                       ? SymbolInfoDouble(symbol, SYMBOL_BID)
                       : SymbolInfoDouble(symbol, SYMBOL_ASK);

        double sl = (type == POSITION_TYPE_BUY) ? price - offset : price + offset;
        if ((type == POSITION_TYPE_BUY && sl <= current_sl) ||
            (type == POSITION_TYPE_SELL && sl >= current_sl)) continue;

        MqlTradeRequest request = {};
        MqlTradeResult result;

        request.action = TRADE_ACTION_SLTP;
        request.symbol = symbol;
        request.position = ticket;
        request.sl = NormalizeDouble(sl, digits);
        request.tp = current_tp;
        request.magic = runner_magic_no;

        if (!OrderSend(request, result))
            Print("Failed to update trailing SL for runner on ", symbol, ". Error: ", result.retcode);
    }
}

// ---------------------------------------------------------------------
// Applies an ATR-based trailing stop to runner trades.
//
// Parameters:
// - symbol         : Trading symbol.
// - _magic_number  : Magic number to identify trades.
// - tf             : Timeframe used for ATR calculation.
// - activation_mult: Multiplier to determine when to activate trailing.
// - trail_mult     : Multiplier to determine trailing distance.
// - atr_period     : ATR period to use.
// - use_bar_close  : If true, use bar close instead of live price.
//
// Logic:
// - Trailing starts only after activation distance is reached.
// - SL is only updated if it moves closer to price (i.e., improves).
// ---------------------------------------------------------------------
void AdjustPosition::trailing_stop_atr(string symbol, int _magic_number, ENUM_TIMEFRAMES tf, double activation_mult,
                                       double trail_mult, int atr_period, bool use_bar_close) {
    double atr = atr_manager.get_atr_value(symbol, tf, atr_period);
    if (atr == EMPTY_VALUE) return;

    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
    int digits = (int) SymbolInfoInteger(symbol, SYMBOL_DIGITS);

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (!PositionSelectByTicket(ticket)) continue;
        if (PositionGetString(POSITION_SYMBOL) != symbol) continue;
        if ((int) PositionGetInteger(POSITION_MAGIC) != _magic_number) continue;

        long type = PositionGetInteger(POSITION_TYPE);
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl = PositionGetDouble(POSITION_SL);
        double price = use_bar_close ? iClose(symbol, tf, 1) : (type == POSITION_TYPE_BUY ? bid : ask);

        double trail_distance = atr * trail_mult;
        double activation_distance = atr * activation_mult;

        bool should_trail = (type == POSITION_TYPE_BUY && price >= entry + activation_distance) ||
                            (type == POSITION_TYPE_SELL && price <= entry - activation_distance);
        if (!should_trail) continue;

        double new_sl = (type == POSITION_TYPE_BUY) ? price - trail_distance : price + trail_distance;
        new_sl = NormalizeDouble(new_sl, digits);

        if ((type == POSITION_TYPE_BUY && sl >= new_sl) ||
            (type == POSITION_TYPE_SELL && sl <= new_sl)) continue;

        if (!trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP)))
            PrintFormat("Trailing SL update failed for %s ticket=%d", symbol, ticket);
        else
            PrintFormat("Trailing SL updated: %s ticket=%d new SL=%.5f", symbol, ticket, new_sl);
    }
}
