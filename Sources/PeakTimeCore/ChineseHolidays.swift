import Foundation

/// Chinese national public holidays (days off), by Beijing calendar date.
/// DeepSeek treats them as off-peak all day, even if they fall in a peak window.
/// Source: timeanddate.com/holidays/china/2026, /2027 and /2028.
/// The 2027 and 2028 calendars are marked preliminary by the source.
/// Adjusted "make-up working weekends" are NOT included: they are already off-peak because they are weekends.
/// UPDATE ANNUALLY when the next year's calendar is published.
public enum ChineseHolidays {
    private static let byYear: [Int: [Int: [Int]]] = [
        2026: [
            1: [1, 2, 3],
            2: [15, 16, 17, 18, 19, 20, 21, 22, 23],
            4: [4, 5, 6],
            5: [1, 2, 3, 4, 5],
            6: [19, 20, 21],
            9: [25, 26, 27],
            10: [1, 2, 3, 4, 5, 6, 7]
        ],
        2027: [
            1: [1],
            2: [5, 6, 7, 8, 9, 10, 11, 12, 13],
            4: [5],
            5: [1, 2, 3, 4, 5],
            6: [9],
            9: [15],
            10: [1, 2, 3, 4, 5, 6, 7]
        ],
        2028: [
            1: [1, 25, 26, 27, 28, 29, 30, 31],
            4: [4],
            5: [1, 28],
            10: [1, 2, 3, 4, 5, 6]
        ]
    ]

    public static let dates: Set<String> = {
        var result = Set<String>()
        for (year, months) in byYear {
            for (month, days) in months {
                for day in days {
                    result.insert(String(format: "%04d-%02d-%02d", year, month, day))
                }
            }
        }
        return result
    }()
}
