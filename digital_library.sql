-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1
-- Generation Time: Nov 08, 2026 at 09:34 AM
-- Server version: 10.4.32-MariaDB
-- PHP Version: 8.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `digital_library`
--

DELIMITER $$
--
-- Procedures
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_issue_copy` (IN `p_copy_identifier` VARCHAR(50), IN `p_member_id` INT, IN `p_due_date` DATETIME)   BEGIN
    DECLARE v_copy_id INT DEFAULT NULL;
    DECLARE v_not_found TINYINT DEFAULT 0;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    IF p_due_date IS NULL OR p_due_date <= NOW() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Due date must be later than the current date and time.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM members WHERE member_id = p_member_id) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Member ID does not exist.';
    END IF;

    SELECT copy_id INTO v_copy_id
    FROM physical_copies
    WHERE copy_identifier = p_copy_identifier;

    IF v_not_found = 1 OR v_copy_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Physical copy identifier does not exist.';
    END IF;

    INSERT INTO transactions
        (copy_id, member_id, issue_date, due_date, status)
    VALUES
        (v_copy_id, p_member_id, NOW(), p_due_date, 'Active');

    COMMIT;

    SELECT 'Book successfully issued.' AS result,
           LAST_INSERT_ID() AS transaction_id;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_recommend_books` (IN `p_member_id` INT, IN `p_limit` INT)   BEGIN
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 50 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Recommendation limit must be between 1 and 50.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM members WHERE member_id = p_member_id
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Member ID does not exist.';
    END IF;

    -- Books in categories the member has borrowed are ranked first.
    -- If the member has no history in a category (or no history at all),
    -- generally popular books are used as fallback recommendations.
    SELECT
        b.book_id,
        b.title,
        b.author,
        b.category,
        COUNT(DISTINCT pc.copy_id) AS available_copies,
        COALESCE(pref.category_borrow_count, 0) AS member_category_borrows,
        COALESCE(pop.book_borrow_count, 0) AS total_book_borrows
    FROM books b
    JOIN physical_copies pc
      ON pc.book_id = b.book_id
     AND pc.status = 'Available'
    LEFT JOIN (
        SELECT
            borrowed_books.category,
            COUNT(*) AS category_borrow_count
        FROM transactions tr
        JOIN physical_copies borrowed_copies
          ON borrowed_copies.copy_id = tr.copy_id
        JOIN books borrowed_books
          ON borrowed_books.book_id = borrowed_copies.book_id
        WHERE tr.member_id = p_member_id
        GROUP BY borrowed_books.category
    ) pref ON pref.category = b.category
    LEFT JOIN (
        SELECT
            borrowed_copies.book_id,
            COUNT(*) AS book_borrow_count
        FROM transactions tr
        JOIN physical_copies borrowed_copies
          ON borrowed_copies.copy_id = tr.copy_id
        GROUP BY borrowed_copies.book_id
    ) pop ON pop.book_id = b.book_id
    WHERE NOT EXISTS (
        SELECT 1
        FROM transactions previous_loan
        JOIN physical_copies previous_copy
          ON previous_copy.copy_id = previous_loan.copy_id
        WHERE previous_loan.member_id = p_member_id
          AND previous_copy.book_id = b.book_id
    )
    GROUP BY
        b.book_id, b.title, b.author, b.category,
        pref.category_borrow_count, pop.book_borrow_count
    ORDER BY
        (pref.category_borrow_count IS NULL) ASC,
        pref.category_borrow_count DESC,
        pop.book_borrow_count DESC,
        b.title ASC
    LIMIT p_limit;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_record_fine_payment` (IN `p_transaction_id` INT, IN `p_amount` DECIMAL(10,2), IN `p_payment_method` VARCHAR(20), IN `p_payment_reference` VARCHAR(100))   BEGIN
    DECLARE v_fine DECIMAL(10,2) DEFAULT NULL;
    DECLARE v_paid DECIMAL(10,2) DEFAULT 0.00;
    DECLARE v_status VARCHAR(20) DEFAULT NULL;
    DECLARE v_found BOOLEAN DEFAULT TRUE;
    DECLARE v_balance DECIMAL(10,2) DEFAULT 0.00;
    DECLARE v_payment_id INT DEFAULT NULL;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = FALSE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Enter a payment amount greater than zero.';
    END IF;

    IF p_payment_method IS NULL OR
       p_payment_method NOT IN ('Cash', 'Card', 'Bank Transfer', 'Online') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid payment method.';
    END IF;

    START TRANSACTION;

    -- Lock the transaction row so two procedure calls cannot overpay the same fine.
    SELECT fine_amount, status
      INTO v_fine, v_status
    FROM transactions
    WHERE transaction_id = p_transaction_id
    FOR UPDATE;

    IF v_found = FALSE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Transaction does not exist.';
    END IF;

    IF v_status <> 'Returned' OR v_fine IS NULL OR v_fine <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'This transaction has no payable assessed fine.';
    END IF;

    SELECT COALESCE(SUM(amount), 0.00)
      INTO v_paid
    FROM fine_payments
    WHERE transaction_id = p_transaction_id;

    SET v_balance = v_fine - v_paid;

    IF p_amount > v_balance THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Payment exceeds the outstanding fine balance.';
    END IF;

    INSERT INTO fine_payments
        (transaction_id, amount, payment_method, payment_reference)
    VALUES
        (p_transaction_id, p_amount, p_payment_method, p_payment_reference);

    SET v_payment_id = LAST_INSERT_ID();
    SET v_balance = v_balance - p_amount;

    COMMIT;

    SELECT
        'Fine payment recorded successfully.' AS result,
        v_payment_id AS payment_id,
        p_transaction_id AS transaction_id,
        p_amount AS amount_paid,
        v_balance AS remaining_balance,
        CASE WHEN v_balance = 0 THEN 'Paid' ELSE 'Partially Paid' END AS payment_status,
        'PKR' AS currency;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_return_copy` (IN `p_transaction_id` INT)   BEGIN
    DECLARE v_copy_id INT;
    DECLARE v_due_date DATETIME;
    DECLARE v_fine_rate DECIMAL(10,2);
    DECLARE v_fine DECIMAL(10,2);
    DECLARE v_not_found BOOLEAN DEFAULT FALSE;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT copy_id, due_date
      INTO v_copy_id, v_due_date
    FROM transactions
    WHERE transaction_id = p_transaction_id
      AND return_date IS NULL
      AND status = 'Active'
    FOR UPDATE;

    IF v_not_found = TRUE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Transaction was not found or the book was already returned.';
    END IF;

    SELECT fine_per_day INTO v_fine_rate
    FROM library_settings
    WHERE setting_id = 1;

    IF v_fine_rate IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Library fine setting is missing.';
    END IF;

    SET v_fine =
        GREATEST(DATEDIFF(CURDATE(), DATE(v_due_date)), 0) * v_fine_rate;

    UPDATE transactions
    SET return_date = NOW(),
        status = 'Returned',
        fine_amount = v_fine
    WHERE transaction_id = p_transaction_id
      AND return_date IS NULL
      AND status = 'Active';

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Transaction was not found or the book was already returned.';
    END IF;

    -- The AFTER UPDATE trigger marks the physical copy Available.
    COMMIT;

    SELECT 'Book successfully returned.' AS result,
           v_fine AS fine_amount,
           'PKR' AS currency;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_search_books` (IN `p_keyword` VARCHAR(255))   BEGIN
    SELECT
        b.book_id,
        b.title,
        b.author,
        b.category,
        b.isbn,
        p.copy_identifier,
        p.status AS copy_status
    FROM books b
    LEFT JOIN physical_copies p ON p.book_id = b.book_id
    WHERE b.title LIKE CONCAT('%', p_keyword, '%')
       OR b.author LIKE CONCAT('%', p_keyword, '%')
       OR b.category LIKE CONCAT('%', p_keyword, '%')
       OR b.isbn LIKE CONCAT('%', p_keyword, '%')
       OR p.copy_identifier LIKE CONCAT('%', p_keyword, '%')
    ORDER BY b.title, p.copy_identifier;
END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `books`
--

CREATE TABLE `books` (
  `book_id` int(11) NOT NULL,
  `title` varchar(255) NOT NULL,
  `author` varchar(255) NOT NULL,
  `category` varchar(100) NOT NULL,
  `isbn` varchar(20) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `books`
--

INSERT INTO `books` (`book_id`, `title`, `author`, `category`, `isbn`, `created_at`) VALUES
(1, 'Clean Code', 'Robert C. Martin', 'Computer Science', '978-0132350884', '2026-11-08 04:54:59'),
(2, 'The Pragmatic Programmer', 'Andrew Hunt and David Thomas', 'Computer Science', '978-0201616224', '2026-11-08 04:54:59'),
(3, 'Introduction to Algorithms', 'Thomas H. Cormen', 'Computer Science', '978-0262033848', '2026-11-08 04:54:59'),
(4, 'Design Patterns', 'Erich Gamma', 'Computer Science', '978-0201633612', '2026-11-08 04:54:59'),
(5, 'Structure and Interpretation of Computer Programs', 'Harold Abelson', 'Computer Science', '978-0262510875', '2026-11-08 04:54:59'),
(6, 'Artificial Intelligence: A Modern Approach', 'Stuart Russell and Peter Norvig', 'Computer Science', '978-0136042594', '2026-11-08 04:54:59'),
(7, 'Computer Networking: A Top-Down Approach', 'James F. Kurose', 'Computer Science', '978-0133594140', '2026-11-08 04:54:59'),
(8, 'Database System Concepts', 'Abraham Silberschatz', 'Computer Science', '978-0073523323', '2026-11-08 04:54:59'),
(9, 'Operating System Concepts', 'Abraham Silberschatz', 'Computer Science', '978-1118063338', '2026-11-08 04:54:59'),
(10, 'Code: The Hidden Language', 'Charles Petzold', 'Computer Science', '978-0735611313', '2026-11-08 04:54:59'),
(11, 'Refactoring', 'Martin Fowler', 'Computer Science', '978-0201485679', '2026-11-08 04:54:59'),
(12, 'Domain-Driven Design', 'Eric Evans', 'Computer Science', '978-0321125217', '2026-11-08 04:54:59'),
(13, 'Patterns of Enterprise Application Architecture', 'Martin Fowler', 'Computer Science', '978-0321127426', '2026-11-08 04:54:59'),
(14, 'The Mythical Man-Month', 'Frederick P. Brooks Jr.', 'Computer Science', '978-0201835953', '2026-11-08 04:54:59'),
(15, 'Hacking: The Art of Exploitation', 'Jon Erickson', 'Security', '978-1593271442', '2026-11-08 04:54:59'),
(16, 'Web Application Hackers Handbook', 'Dafydd Stuttard', 'Security', '978-0470170779', '2026-11-08 04:54:59'),
(17, 'TCP/IP Illustrated, Volume 1', 'W. Richard Stevens', 'Networking', '978-0321336316', '2026-11-08 04:54:59'),
(18, 'Advanced Programming in the UNIX Environment', 'W. Richard Stevens', 'Operating Systems', '978-0321637734', '2026-11-08 04:54:59'),
(19, 'Compilers: Principles, Techniques, and Tools', 'Alfred V. Aho', 'Computer Science', '978-0321486813', '2026-11-08 04:54:59'),
(20, 'The C Programming Language', 'Brian W. Kernighan and Dennis M. Ritchie', 'Programming', '978-0103627632', '2026-11-08 04:54:59'),
(21, 'Effective C++', 'Scott Meyers', 'Programming', '978-0321334879', '2026-11-08 04:54:59'),
(22, 'Programming: Principles and Practice Using C++', 'Bjarne Stroustrup', 'Programming', '978-0321543725', '2026-11-08 04:54:59'),
(23, 'The Rust Programming Language', 'Steve Klabnik and Carol Nichols', 'Programming', '978-1593278281', '2026-11-08 04:54:59'),
(24, 'Fluent Python', 'Luciano Ramalho', 'Programming', '978-1491946008', '2026-11-08 04:54:59'),
(25, 'Python Crash Course', 'Eric Matthes', 'Programming', '978-1593279288', '2026-11-08 04:54:59'),
(26, 'JavaScript: The Good Parts', 'Douglas Crockford', 'Programming', '978-0596517748', '2026-11-08 04:54:59'),
(27, 'Eloquent JavaScript', 'Marijn Haverbeke', 'Programming', '978-1593279509', '2026-11-08 04:54:59'),
(28, 'Head First Design Patterns', 'Eric Freeman', 'Computer Science', '978-0596007126', '2026-11-08 04:54:59'),
(29, 'Continuous Delivery', 'Jez Humble and David Farley', 'DevOps', '978-0321601919', '2026-11-08 04:54:59'),
(30, 'Site Reliability Engineering', 'Betsy Beyer', 'DevOps', '978-1491929123', '2026-11-08 04:54:59'),
(31, 'Microservices Patterns', 'Chris Richardson', 'Software Architecture', '978-1617294549', '2026-11-08 04:54:59'),
(32, 'Building Microservices', 'Sam Newman', 'Software Architecture', '978-1491950357', '2026-11-08 04:54:59'),
(33, 'The DevOps Handbook', 'Gene Kim', 'DevOps', '978-1942788003', '2026-11-08 04:54:59'),
(34, 'Phoenix Project', 'Gene Kim', 'DevOps', '978-0988262591', '2026-11-08 04:54:59'),
(35, 'Algorithms to Live By', 'Brian Christian and Tom Griffiths', 'Computer Science', '978-1627790369', '2026-11-08 04:54:59'),
(36, 'Deep Learning', 'Ian Goodfellow', 'Artificial Intelligence', '978-0262035613', '2026-11-08 04:54:59'),
(37, 'Hands-On Machine Learning with Scikit-Learn and TensorFlow', 'Aurélien Géron', 'Artificial Intelligence', '978-1492032649', '2026-11-08 04:54:59'),
(38, 'Pattern Recognition and Machine Learning', 'Christopher M. Bishop', 'Artificial Intelligence', '978-0387310732', '2026-11-08 04:54:59'),
(39, 'Reinforcement Learning', 'Richard S. Sutton and Andrew G. Barto', 'Artificial Intelligence', '978-0262039246', '2026-11-08 04:54:59'),
(40, 'Designing Data-Intensive Applications', 'Martin Kleppmann', 'Computer Science', '978-1449373320', '2026-11-08 04:54:59'),
(41, 'The Linux Programming Interface', 'Michael Kerrisk', 'Operating Systems', '978-1593272203', '2026-11-08 04:54:59'),
(42, 'Effective Java', 'Joshua Bloch', 'Programming', '978-0134685991', '2026-11-08 04:54:59'),
(43, 'Java Concurrency in Practice', 'Brian Goetz', 'Programming', '978-0321349606', '2026-11-08 04:54:59'),
(44, 'Clean Architecture', 'Robert C. Martin', 'Computer Science', '978-0134494166', '2026-11-08 04:54:59'),
(45, 'Working Effectively with Legacy Code', 'Michael Feathers', 'Computer Science', '978-0131177055', '2026-11-08 04:54:59'),
(46, 'Test Driven Development by Example', 'Kent Beck', 'Computer Science', '978-0321146533', '2026-11-08 04:54:59'),
(47, 'Extreme Programming Explained', 'Kent Beck', 'Computer Science', '978-0321278654', '2026-11-08 04:54:59'),
(48, 'The Art of Computer Programming, Vol. 1', 'Donald E. Knuth', 'Computer Science', '978-0201896831', '2026-11-08 04:54:59'),
(49, 'The Art of Computer Programming, Vol. 2', 'Donald E. Knuth', 'Computer Science', '978-0201896848', '2026-11-08 04:54:59'),
(50, 'The Art of Computer Programming, Vol. 3', 'Donald E. Knuth', 'Computer Science', '978-0201896855', '2026-11-08 04:54:59'),
(51, 'Fundamentals of Electric Circuits', 'Charles K. Alexander and Matthew N.O. Sadiku', 'Electrical Engineering', '978-0073380575', '2026-11-08 04:54:59'),
(52, 'Engineering Circuit Analysis', 'William H. Hayt and Jack E. Kemmerly', 'Electrical Engineering', '978-0073529578', '2026-11-08 04:54:59'),
(53, 'Microelectronic Circuits', 'Adel S. Sedra and Kenneth C. Smith', 'Electrical Engineering', '978-0195323030', '2026-11-08 04:54:59'),
(54, 'Power System Analysis and Design', 'J. Duncan Glover and Mulukutla S. Sarma', 'Electrical Engineering', '978-1111425777', '2026-11-08 04:54:59'),
(55, 'Electric Machinery Fundamentals', 'Stephen J. Chapman', 'Electrical Engineering', '978-0073529547', '2026-11-08 04:54:59'),
(56, 'Digital Logic and Computer Design', 'M. Morris Mano', 'Electrical Engineering', '978-0132145307', '2026-11-08 04:54:59'),
(57, 'Digital Design', 'M. Morris Mano and Michael D. Ciletti', 'Electrical Engineering', '978-0132774208', '2026-11-08 04:54:59'),
(58, 'Control Systems Engineering', 'Norman S. Nise', 'Electrical Engineering', '978-1118170519', '2026-11-08 04:54:59'),
(59, 'Electromagnetics with Applications', 'John Daniel Kraus', 'Electrical Engineering', '978-0072899794', '2026-11-08 04:54:59'),
(60, 'Principles of Communication Systems', 'Herbert Taub and Donald L. Schilling', 'Electrical Engineering', '978-0070628861', '2026-11-08 04:54:59'),
(61, 'Communication Systems', 'Simon Haykin', 'Electrical Engineering', '978-0471697367', '2026-11-08 04:54:59'),
(62, 'Signals and Systems', 'Alan V. Oppenheim and Alan S. Willsky', 'Electrical Engineering', '978-0138147573', '2026-11-08 04:54:59'),
(63, 'Electronic Devices and Circuit Theory', 'Robert L. Boylestad and Louis Nashelsky', 'Electrical Engineering', '978-0135026496', '2026-11-08 04:54:59'),
(64, 'VLSI Design', 'K. Lal Kishore', 'Electrical Engineering', '978-9380570549', '2026-11-08 04:54:59'),
(65, 'Antenna Theory: Analysis and Design', 'Constantine A. Balanis', 'Electrical Engineering', '978-0471667828', '2026-11-08 04:54:59'),
(66, 'RF Circuit Design', 'Chris Bowick', 'Electrical Engineering', '978-0750685184', '2026-11-08 04:54:59'),
(67, 'The Art of Electronics', 'Paul Horowitz and Winfield Hill', 'Electrical Engineering', '978-0521809267', '2026-11-08 04:54:59'),
(68, 'Analysis of Faulted Power Systems', 'Paul M. Anderson', 'Electrical Engineering', '978-0780311457', '2026-11-08 04:54:59'),
(69, 'Modern Power Systems Control', 'Elgerd', 'Electrical Engineering', '978-0070191839', '2026-11-08 04:54:59'),
(70, 'Electrical Machines, Drives, and Power Systems', 'Theodore Wildi', 'Electrical Engineering', '978-0131776913', '2026-11-08 04:54:59'),
(71, 'Calculus: Early Transcendentals', 'James Stewart', 'Mathematics', '978-1285741550', '2026-11-08 04:54:59'),
(72, 'Thomas Calculus', 'George B. Thomas Jr.', 'Mathematics', '978-0321587992', '2026-11-08 04:54:59'),
(73, 'Linear Algebra and Its Applications', 'Gilbert Strang', 'Mathematics', '978-0030105678', '2026-11-08 04:54:59'),
(74, 'Advanced Engineering Mathematics', 'Erwin Kreyszig', 'Mathematics', '978-0470458365', '2026-11-08 04:54:59'),
(75, 'Differential Equations with Applications', 'Dennis G. Zill', 'Mathematics', '978-1305965720', '2026-11-08 04:54:59'),
(76, 'Probability and Statistics for Engineers and Scientists', 'Ronald E. Walpole', 'Mathematics', '978-0321629110', '2026-11-08 04:54:59'),
(77, 'Discrete Mathematics and Its Applications', 'Kenneth H. Rosen', 'Mathematics', '978-0073383095', '2026-11-08 04:54:59'),
(78, 'Complex Variables and Applications', 'James Ward Brown and Ruel V. Churchill', 'Mathematics', '978-0073383170', '2026-11-08 04:54:59'),
(79, 'Numerical Analysis', 'Richard L. Burden and J. Douglas Faires', 'Mathematics', '978-0538733519', '2026-11-08 04:54:59'),
(80, 'Vector Calculus', 'Jerrold E. Marsden and Anthony Tromba', 'Mathematics', '978-1429215084', '2026-11-08 04:54:59'),
(81, 'University Physics with Modern Physics', 'Hugh D. Young and Roger A. Freedman', 'Physics', '978-0321973610', '2026-11-08 04:54:59'),
(82, 'Fundamentals of Physics', 'David Halliday, Robert Resnick, and Jearl Walker', 'Physics', '978-1118230718', '2026-11-08 04:54:59'),
(83, 'Feynman Lectures on Physics', 'Richard P. Feynman', 'Physics', '978-0201021158', '2026-11-08 04:54:59'),
(84, 'Classical Mechanics', 'Herbert Goldstein', 'Physics', '978-0201657029', '2026-11-08 04:54:59'),
(85, 'Introduction to Electrodynamics', 'David J. Griffiths', 'Physics', '978-1108420418', '2026-11-08 04:54:59'),
(86, 'Quantum Mechanics: Concepts and Applications', 'Nouredine Zettili', 'Physics', '978-0470026793', '2026-11-08 04:54:59'),
(87, 'Thermal Physics', 'Charles Kittel and Herbert Kroemer', 'Physics', '978-0716710882', '2026-11-08 04:54:59'),
(88, 'Optics', 'Eugene Hecht', 'Physics', '978-0321543275', '2026-11-08 04:54:59'),
(89, 'Solid State Physics', 'Neil W. Ashcroft and N. David Mermin', 'Physics', '978-0030839931', '2026-11-08 04:54:59'),
(90, 'Nuclear Physics', 'Irving Kaplan', 'Physics', '978-0201036978', '2026-11-08 04:54:59'),
(91, 'Organic Chemistry', 'Paula Yurkanis Bruice', 'Chemistry', '978-0134074580', '2026-11-08 04:54:59'),
(92, 'Inorganic Chemistry', 'Gary L. Miessler', 'Chemistry', '978-0321811059', '2026-11-08 04:54:59'),
(93, 'Physical Chemistry', 'Peter Atkins and Julio de Paula', 'Chemistry', '978-0199543373', '2026-11-08 04:54:59'),
(94, 'Analytical Chemistry', 'Douglas A. Skoog', 'Chemistry', '978-0495558286', '2026-11-08 04:54:59'),
(95, 'Biochemistry', 'Jeremy M. Berg', 'Chemistry', '978-1429229364', '2026-11-08 04:54:59'),
(96, 'Chemical Engineering Thermodynamics', 'J.M. Smith', 'Chemical Engineering', '978-0073104454', '2026-11-08 04:54:59'),
(97, 'Transport Phenomena', 'R. Byron Bird', 'Chemical Engineering', '978-0470115398', '2026-11-08 04:54:59'),
(98, 'Unit Operations of Chemical Engineering', 'Warren L. McCabe', 'Chemical Engineering', '978-0072848235', '2026-11-08 04:54:59'),
(99, 'Elements of Chemical Reaction Engineering', 'H. Scott Fogler', 'Chemical Engineering', '978-0130473943', '2026-11-08 04:54:59'),
(100, 'Fluid Mechanics', 'Frank M. White', 'Mechanical Engineering', '978-0073398273', '2026-11-08 04:54:59'),
(101, 'Thermodynamics: An Engineering Approach', 'Yunus A. Cengel and Michael A. Boles', 'Mechanical Engineering', '978-0073398174', '2026-11-08 04:54:59'),
(102, 'Heat Transfer', 'J.P. Holman', 'Mechanical Engineering', '978-0073529219', '2026-11-08 04:54:59'),
(103, 'Mechanics of Materials', 'Ferdinand P. Beer', 'Mechanical Engineering', '978-0073398235', '2026-11-08 04:54:59'),
(104, 'Theory of Machines and Mechanisms', 'John J. Uicker', 'Mechanical Engineering', '978-0195371238', '2026-11-08 04:54:59'),
(105, 'Machine Design', 'Robert L. Norton', 'Mechanical Engineering', '978-0131433588', '2026-11-08 04:54:59'),
(106, 'Manufacturing Processes for Engineering Materials', 'Serope Kalpakjian', 'Mechanical Engineering', '978-0132272711', '2026-11-08 04:54:59'),
(107, 'Engineering Mechanics: Statics', 'R.C. Hibbeler', 'Mechanical Engineering', '978-0133918922', '2026-11-08 04:54:59'),
(108, 'Engineering Mechanics: Dynamics', 'R.C. Hibbeler', 'Mechanical Engineering', '978-0133915389', '2026-11-08 04:54:59'),
(109, 'Vibration of Continuous Systems', 'Singiresu S. Rao', 'Mechanical Engineering', '978-0470771174', '2026-11-08 04:54:59'),
(110, 'Finite Element Analysis', 'Seyed Mohammad Zahedi', 'Mechanical Engineering', '978-1118852330', '2026-11-08 04:54:59'),
(111, 'A Brief History of Time', 'Stephen Hawking', 'Science Popular', '978-0553380163', '2026-11-08 04:54:59'),
(112, 'Cosmos', 'Carl Sagan', 'Science Popular', '978-0345539434', '2026-11-08 04:54:59'),
(113, 'Sapiens: A Brief History of Humankind', 'Yuval Noah Harari', 'History', '978-0062316097', '2026-11-08 04:54:59'),
(114, 'Homo Deus', 'Yuval Noah Harari', 'History', '978-0062464316', '2026-11-08 04:54:59'),
(115, '21 Lessons for the 21st Century', 'Yuval Noah Harari', 'History', '978-0385542869', '2026-11-08 04:54:59'),
(116, 'Educated', 'Tara Westover', 'Memoir', '978-0399590504', '2026-11-08 04:54:59'),
(117, 'Becoming', 'Michelle Obama', 'Memoir', '978-1524763138', '2026-11-08 04:54:59'),
(118, 'Atomic Habits', 'James Clear', 'Self-Help', '978-0735211292', '2026-11-08 04:54:59'),
(119, 'The Power of Habit', 'Charles Duhigg', 'Self-Help', '978-0812981605', '2026-11-08 04:54:59'),
(120, 'Thinking, Fast and Slow', 'Daniel Kahneman', 'Psychology', '978-0374533557', '2026-11-08 04:54:59'),
(121, 'Influence: The Psychology of Persuasion', 'Robert Cialdini', 'Psychology', '978-0061241890', '2026-11-08 04:54:59'),
(122, 'Outliers', 'Malcolm Gladwell', 'Sociology', '978-0316017930', '2026-11-08 04:54:59'),
(123, 'Tipping Point', 'Malcolm Gladwell', 'Sociology', '978-0316346627', '2026-11-08 04:54:59'),
(124, 'Good to Great', 'Jim Collins', 'Business', '978-0066620995', '2026-11-08 04:54:59'),
(125, 'The Lean Startup', 'Eric Ries', 'Business', '978-0307887894', '2026-11-08 04:54:59'),
(126, 'Zero to One', 'Peter Thiel', 'Business', '978-0804139299', '2026-11-08 04:54:59'),
(127, 'Principles: Life and Work', 'Ray Dalio', 'Business', '978-1501124020', '2026-11-08 04:54:59'),
(128, 'Rich Dad Poor Dad', 'Robert T. Kiyosaki', 'Finance', '978-1612680194', '2026-11-08 04:54:59'),
(129, 'The Intelligent Investor', 'Benjamin Graham', 'Finance', '978-0060555665', '2026-11-08 04:54:59'),
(130, 'Security Analysis', 'Benjamin Graham and David Dodd', 'Finance', '978-0071592537', '2026-11-08 04:54:59'),
(131, 'A Random Walk Down Wall Street', 'Burton G. Malkiel', 'Finance', '978-0393358384', '2026-11-08 04:54:59'),
(132, 'Economics', 'Paul Samuelson and William Nordhaus', 'Economics', '978-0073511290', '2026-11-08 04:54:59'),
(133, 'Principles of Economics', 'N. Gregory Mankiw', 'Economics', '978-1305585126', '2026-11-08 04:54:59'),
(134, 'Capital in the Twenty-First Century', 'Thomas Piketty', 'Economics', '978-0674430006', '2026-11-08 04:54:59'),
(135, 'The Wealth of Nations', 'Adam Smith', 'Economics', '978-0140432084', '2026-11-08 04:54:59'),
(136, 'Freakonomics', 'Steven D. Levitt and Stephen J. Dubner', 'Economics', '978-0060731335', '2026-11-08 04:54:59'),
(137, 'Artificial Intelligence for Humans', 'Jeff Heaton', 'Artificial Intelligence', '978-1503373310', '2026-11-08 04:54:59'),
(138, 'Neural Networks and Deep Learning', 'Michael Nielsen', 'Artificial Intelligence', '978-1507314277', '2026-11-08 04:54:59'),
(139, 'Data Mining: Concepts and Techniques', 'Jiawei Han', 'Computer Science', '978-0123814791', '2026-11-08 04:54:59'),
(140, 'Information Retrieval', 'Christopher D. Manning', 'Computer Science', '978-0521865715', '2026-11-08 04:54:59'),
(141, 'Software Engineering', 'Ian Sommerville', 'Computer Science', '978-0137035151', '2026-11-08 04:54:59'),
(142, 'Software Engineering: A Practitioner Approach', 'Roger S. Pressman', 'Computer Science', '978-0078022128', '2026-11-08 04:54:59'),
(143, 'Computer Architecture: A Quantitative Approach', 'John L. Hennessy and David A. Patterson', 'Computer Science', '978-0123838728', '2026-11-08 04:54:59'),
(144, 'Digital Signal Processing', 'John G. Proakis and Dimitris G. Manolakis', 'Electrical Engineering', '978-0131873742', '2026-11-08 04:54:59'),
(145, 'Power Electronics: Converters, Applications, and Design', 'Ned Mohan', 'Electrical Engineering', '978-0471226932', '2026-11-08 04:54:59'),
(146, 'Semiconductor Physics and Devices', 'Donald A. Neamen', 'Electrical Engineering', '978-0073529585', '2026-11-08 04:54:59'),
(147, 'Electronic Principles', 'Albert Paul Malvino', 'Electrical Engineering', '978-0073373881', '2026-11-08 04:54:59'),
(148, 'Electric Power Systems', 'A.E. Fitzgerald', 'Electrical Engineering', '978-0070211513', '2026-11-08 04:54:59'),
(149, 'Modern Control Engineering', 'Katsuhiko Ogata', 'Electrical Engineering', '978-0136156734', '2026-11-08 04:54:59'),
(150, 'Fundamentals of Logic Design', 'Charles H. Roth Jr.', 'Electrical Engineering', '978-1133628477', '2026-11-08 04:54:59'),
(151, 'Communication Engineering', 'Anokh Singh', 'Electrical Engineering', '978-8121903912', '2026-11-08 04:54:59'),
(152, 'Electric Power Distribution System Engineering', 'Turan Gönen', 'Electrical Engineering', '978-1455502127', '2026-11-08 04:54:59'),
(153, 'High Voltage Engineering', 'M.S. Naidu and V. Kamaraju', 'Electrical Engineering', '978-0070669284', '2026-11-08 04:54:59'),
(154, 'Electrical Power Systems Quality', 'Roger C. Dugan', 'Electrical Engineering', '978-0071761338', '2026-11-08 04:54:59'),
(155, 'Principles of Electric Machines and Power Electronics', 'P.C. Sen', 'Electrical Engineering', '978-0471670995', '2026-11-08 04:54:59'),
(156, 'Automatic Control Systems', 'Benjamin C. Kuo', 'Electrical Engineering', '978-0471134763', '2026-11-08 04:54:59'),
(157, 'Microwave Engineering', 'David M. Pozar', 'Electrical Engineering', '978-0470631553', '2026-11-08 04:54:59'),
(158, 'Fiber Optic Communications', 'Joseph C. Palais', 'Electrical Engineering', '978-0130085108', '2026-11-08 04:54:59'),
(159, 'Digital Integrated Circuits', 'Jan M. Rabaey', 'Electrical Engineering', '978-0130909992', '2026-11-08 04:54:59'),
(160, 'Elements of Electromagnetics', 'Matthew N.O. Sadiku', 'Electrical Engineering', '978-0195387759', '2026-11-08 04:54:59'),
(161, 'Electric Energy Systems Theory', 'Olle I. Elgerd', 'Electrical Engineering', '978-0070191830', '2026-11-08 04:54:59'),
(162, 'Power Generation, Operation, and Control', 'Allen J. Wood and Bruce F. Wollenberg', 'Electrical Engineering', '978-0471790556', '2026-11-08 04:54:59'),
(163, 'Renewable and Efficient Electric Power Systems', 'Gilbert M. Masters', 'Electrical Engineering', '978-0470280638', '2026-11-08 04:54:59'),
(164, 'Smart Grid: Technology and Applications', 'Janaka Ekanayake', 'Electrical Engineering', '978-0470973936', '2026-11-08 04:54:59'),
(165, 'Wind Energy Engineering', 'Pramod Jain', 'Electrical Engineering', '978-0071714840', '2026-11-08 04:54:59'),
(166, 'Photovoltaic Systems Engineering', 'Roger A. Messenger', 'Electrical Engineering', '978-1439840184', '2026-11-08 04:54:59'),
(167, 'Electric Vehicle Engineering', 'Per Enge', 'Electrical Engineering', '978-1260128918', '2026-11-08 04:54:59'),
(168, 'Introduction to Mechatronics', 'Appu Kuttan KK', 'Mechatronics', '978-0195690941', '2026-11-08 04:54:59'),
(169, 'Robotics: Modelling, Planning and Control', 'Bruno Siciliano', 'Robotics', '978-1846286415', '2026-11-08 04:54:59'),
(170, 'Introduction to Robotics', 'John J. Craig', 'Robotics', '978-0201543612', '2026-11-08 04:54:59'),
(171, 'Autonomous Robots', 'George A. Bekey', 'Robotics', '978-0262025782', '2026-11-08 04:54:59'),
(172, 'Embedded Systems Design', 'Steve Heath', 'Embedded Systems', '978-0750654784', '2026-11-08 04:54:59'),
(173, 'ARM Cortex-M Microcontrollers', 'Yiu', 'Embedded Systems', '978-0124080829', '2026-11-08 04:54:59'),
(174, 'Microcontrollers and Embedded Systems', 'Muhammad Ali Mazidi', 'Embedded Systems', '978-0131194045', '2026-11-08 04:54:59'),
(175, 'The C++ Programming Language', 'Bjarne Stroustrup', 'Programming', '978-0321563842', '2026-11-08 04:54:59'),
(176, 'Programming in C', 'Stephen G. Kochan', 'Programming', '978-0672326660', '2026-11-08 04:54:59'),
(177, 'Python Cookbook', 'David Beazley and Brian K. Jones', 'Programming', '978-1449340377', '2026-11-08 04:54:59'),
(178, 'Head First Java', 'Kathy Sierra and Bert Bates', 'Programming', '978-0596009208', '2026-11-08 04:54:59'),
(179, 'C# in Depth', 'Jon Skeet', 'Programming', '978-1617294532', '2026-11-08 04:54:59'),
(180, 'Pro C# 9 with .NET 5', 'Andrew Troelsen and Philip Japikse', 'Programming', '978-1484266327', '2026-11-08 04:54:59'),
(181, 'Go Programming Language', 'Alan A. A. Donovan and Brian W. Kernighan', 'Programming', '978-0134190440', '2026-11-08 04:54:59'),
(182, 'Programming TypeScript', 'Boris Cherny', 'Programming', '978-1492037651', '2026-11-08 04:54:59'),
(183, 'Learning React', 'Alex Banks and Eve Porcello', 'Web Development', '978-1492054627', '2026-11-08 04:54:59'),
(184, 'React Up and Running', 'Stoyan Stefanov', 'Web Development', '978-1491931820', '2026-11-08 04:54:59'),
(185, 'Node.js Design Patterns', 'Mario Casciaro and Luciano Mammino', 'Web Development', '978-1839214110', '2026-11-08 04:54:59'),
(186, 'High Performance Browser Networking', 'Ilya Grigorik', 'Web Development', '978-1449344764', '2026-11-08 04:54:59'),
(187, 'Designing Web APIs', 'Brenda Jin and Saurabh Sahni', 'Web Development', '978-1492026921', '2026-11-08 04:54:59'),
(188, 'RESTful Web APIs', 'Leonard Richardson and Mike Amundsen', 'Web Development', '978-1449358068', '2026-11-08 04:54:59'),
(189, 'SQL in 10 Minutes, Sams Teach Yourself', 'Ben Forta', 'Database', '978-0672336077', '2026-11-08 04:54:59'),
(190, 'Learning SQL', 'Alan Beaulieu', 'Database', '978-1492057611', '2026-11-08 04:54:59'),
(191, 'High Performance MySQL', 'Baron Schwartz', 'Database', '978-1492014201', '2026-11-08 04:54:59'),
(192, 'MongoDB: The Definitive Guide', 'Kristina Chodorow', 'Database', '978-1491954462', '2026-11-08 04:54:59'),
(193, 'Redis in Action', 'Josiah L. Carlson', 'Database', '978-1617290855', '2026-11-08 04:54:59'),
(194, 'The Elements of Statistical Learning', 'Trevor Hastie, Robert Tibshirani and Jerome Friedman', 'Mathematics', '978-0387848570', '2026-11-08 04:54:59'),
(195, 'Introduction to Linear Algebra', 'Gilbert Strang', 'Mathematics', '978-0980232776', '2026-11-08 04:54:59'),
(196, 'Computer Organization and Design', 'David A. Patterson and John L. Hennessy', 'Computer Science', '978-0124077263', '2026-11-08 04:54:59'),
(197, 'The Web Application Hacker\'s Handbook', 'Dafydd Stuttard and Marcus Pinto', 'Security', '978-1118026472', '2026-11-08 04:54:59'),
(198, 'Practical Electronics for Inventors', 'Paul Scherz and Simon Monk', 'Electrical Engineering', '978-1259587542', '2026-11-08 04:54:59'),
(199, 'The Design of Everyday Things', 'Don Norman', 'Design', '978-0465050659', '2026-11-08 04:54:59'),
(200, 'Surely You\'re Joking, Mr. Feynman!', 'Richard P. Feynman', 'Science Popular', '978-0393355628', '2026-11-08 04:54:59');

-- --------------------------------------------------------

--
-- Table structure for table `fine_payments`
--

CREATE TABLE `fine_payments` (
  `payment_id` int(11) NOT NULL,
  `transaction_id` int(11) NOT NULL,
  `amount` decimal(10,2) NOT NULL,
  `payment_method` enum('Cash','Card','Bank Transfer','Online') NOT NULL DEFAULT 'Cash',
  `payment_reference` varchar(100) DEFAULT NULL,
  `payment_date` datetime NOT NULL DEFAULT current_timestamp(),
  `notes` varchar(255) DEFAULT NULL
) ;

--
-- Triggers `fine_payments`
--
DELIMITER $$
CREATE TRIGGER `trg_fine_payments_before_insert` BEFORE INSERT ON `fine_payments` FOR EACH ROW BEGIN
    DECLARE v_fine DECIMAL(10,2) DEFAULT NULL;
    DECLARE v_paid DECIMAL(10,2) DEFAULT 0.00;
    DECLARE v_status VARCHAR(20) DEFAULT NULL;
    DECLARE v_found BOOLEAN DEFAULT TRUE;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_found = FALSE;

    IF NEW.amount IS NULL OR NEW.amount <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Payment amount must be greater than zero.';
    END IF;

    SELECT fine_amount, status
      INTO v_fine, v_status
    FROM transactions
    WHERE transaction_id = NEW.transaction_id;

    IF v_found = FALSE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Transaction does not exist.';
    END IF;

    IF v_status <> 'Returned' OR v_fine IS NULL OR v_fine <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'This transaction has no payable assessed fine.';
    END IF;

    SELECT COALESCE(SUM(amount), 0.00)
      INTO v_paid
    FROM fine_payments
    WHERE transaction_id = NEW.transaction_id;

    IF NEW.amount > (v_fine - v_paid) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Payment exceeds the outstanding fine balance.';
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `library_settings`
--

CREATE TABLE `library_settings` (
  `setting_id` tinyint(4) NOT NULL,
  `fine_per_day` decimal(10,2) NOT NULL DEFAULT 50.00,
  `loan_period_days` int(11) NOT NULL DEFAULT 14
) ;

--
-- Dumping data for table `library_settings`
--

INSERT INTO `library_settings` (`setting_id`, `fine_per_day`, `loan_period_days`) VALUES
(1, 50.00, 14);

-- --------------------------------------------------------

--
-- Table structure for table `members`
--

CREATE TABLE `members` (
  `member_id` int(11) NOT NULL,
  `name` varchar(100) NOT NULL,
  `email` varchar(100) DEFAULT NULL,
  `phone` varchar(20) DEFAULT NULL,
  `join_date` date NOT NULL DEFAULT curdate()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `members`
--

INSERT INTO `members` (`member_id`, `name`, `email`, `phone`, `join_date`) VALUES
(1, 'khabib nurmagomedov', 'aimal.kareem@neduet.edu.pk', '+92-300-1234567', '2026-11-08'),
(2, 'islam mackachev', 'ahmed.khan@gmail.com', '+92-321-9876543', '2026-11-08'),
(3, 'illia toporia', 'fatima.ali@yahoo.com', '+92-333-4567890', '2026-11-08'),
(4, 'george st.pierre', 'bilal.s@outlook.com', '+92-312-5551234', '2026-11-08'),
(5, 'morales', 'ayesha.malik@gmail.com', '+92-302-7788990', '2026-11-08'),
(6, 'john jones', 'zainab.noor@neduet.edu.pk', '+92-315-4433221', '2026-11-08'),
(7, 'alaxender volk', 'hamza.sheikh@gmail.com', '+92-304-9988776', '2026-11-08'),
(8, 'mighty mouse', 'sana.tariq@yahoo.com', '+92-322-1122334', '2026-11-08'),
(9, 'conor mcgregor', 'usman.ghani@gmail.com', '+92-334-6677889', '2026-11-08'),
(10, 'ian gerry', 'hira.riaz@outlook.com', '+92-301-3344556', '2026-11-08');

-- --------------------------------------------------------

--
-- Table structure for table `physical_copies`
--

CREATE TABLE `physical_copies` (
  `copy_id` int(11) NOT NULL,
  `book_id` int(11) NOT NULL,
  `copy_identifier` varchar(50) NOT NULL,
  `status` enum('Available','Issued','Damaged','Lost') NOT NULL DEFAULT 'Available'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `physical_copies`
--

INSERT INTO `physical_copies` (`copy_id`, `book_id`, `copy_identifier`, `status`) VALUES
(1, 73, 'B73-C1', 'Available'),
(2, 89, 'B89-C1', 'Available'),
(3, 129, 'B129-C1', 'Available'),
(4, 136, 'B136-C1', 'Available'),
(5, 121, 'B121-C1', 'Available'),
(6, 113, 'B113-C1', 'Available'),
(7, 114, 'B114-C1', 'Available'),
(8, 124, 'B124-C1', 'Available'),
(9, 161, 'B161-C1', 'Available'),
(10, 69, 'B69-C1', 'Available'),
(11, 148, 'B148-C1', 'Available'),
(12, 60, 'B60-C1', 'Available'),
(13, 153, 'B153-C1', 'Available'),
(14, 130, 'B130-C1', 'Available'),
(15, 165, 'B165-C1', 'Available'),
(16, 154, 'B154-C1', 'Available'),
(17, 98, 'B98-C1', 'Available'),
(18, 59, 'B59-C1', 'Available'),
(19, 96, 'B96-C1', 'Available'),
(20, 147, 'B147-C1', 'Available'),
(21, 51, 'B51-C1', 'Available'),
(22, 77, 'B77-C1', 'Available'),
(23, 78, 'B78-C1', 'Available'),
(24, 101, 'B101-C1', 'Available'),
(25, 103, 'B103-C1', 'Available'),
(26, 100, 'B100-C1', 'Available'),
(27, 132, 'B132-C1', 'Available'),
(28, 8, 'B8-C1', 'Available'),
(29, 102, 'B102-C1', 'Available'),
(30, 55, 'B55-C1', 'Available'),
(31, 52, 'B52-C1', 'Available'),
(32, 146, 'B146-C1', 'Available'),
(33, 142, 'B142-C1', 'Available'),
(34, 20, 'B20-C1', 'Available'),
(35, 139, 'B139-C1', 'Available'),
(36, 143, 'B143-C1', 'Available'),
(37, 196, 'B196-C1', 'Available'),
(38, 173, 'B173-C1', 'Available'),
(39, 158, 'B158-C1', 'Available'),
(40, 99, 'B99-C1', 'Available'),
(41, 159, 'B159-C1', 'Available'),
(42, 45, 'B45-C1', 'Available'),
(43, 174, 'B174-C1', 'Available'),
(44, 105, 'B105-C1', 'Available'),
(45, 70, 'B70-C1', 'Available'),
(46, 144, 'B144-C1', 'Available'),
(47, 56, 'B56-C1', 'Available'),
(48, 106, 'B106-C1', 'Available'),
(49, 1, 'B1-C1', 'Issued'),
(50, 57, 'B57-C1', 'Available'),
(51, 7, 'B7-C1', 'Available'),
(52, 108, 'B108-C1', 'Available'),
(53, 107, 'B107-C1', 'Available'),
(54, 91, 'B91-C1', 'Available'),
(55, 181, 'B181-C1', 'Available'),
(56, 44, 'B44-C1', 'Available'),
(57, 42, 'B42-C1', 'Available'),
(58, 63, 'B63-C1', 'Available'),
(59, 6, 'B6-C1', 'Available'),
(60, 149, 'B149-C1', 'Available'),
(61, 141, 'B141-C1', 'Available'),
(62, 62, 'B62-C1', 'Available'),
(63, 135, 'B135-C1', 'Available'),
(64, 53, 'B53-C1', 'Available'),
(65, 104, 'B104-C1', 'Available'),
(66, 160, 'B160-C1', 'Available'),
(67, 168, 'B168-C1', 'Available'),
(68, 93, 'B93-C1', 'Available'),
(69, 83, 'B83-C1', 'Available'),
(70, 90, 'B90-C1', 'Available'),
(71, 11, 'B11-C1', 'Available'),
(72, 170, 'B170-C1', 'Available'),
(73, 2, 'B2-C1', 'Issued'),
(74, 4, 'B4-C1', 'Available'),
(75, 84, 'B84-C1', 'Available'),
(76, 14, 'B14-C1', 'Available'),
(77, 48, 'B48-C1', 'Available'),
(78, 49, 'B49-C1', 'Available'),
(79, 50, 'B50-C1', 'Available'),
(80, 171, 'B171-C1', 'Available'),
(81, 3, 'B3-C1', 'Available'),
(82, 36, 'B36-C1', 'Available'),
(83, 39, 'B39-C1', 'Available'),
(84, 5, 'B5-C1', 'Issued'),
(85, 125, 'B125-C1', 'Available'),
(86, 122, 'B122-C1', 'Available'),
(87, 123, 'B123-C1', 'Available'),
(88, 12, 'B12-C1', 'Available'),
(89, 13, 'B13-C1', 'Available'),
(90, 46, 'B46-C1', 'Available'),
(91, 47, 'B47-C1', 'Available'),
(92, 21, 'B21-C1', 'Available'),
(93, 17, 'B17-C1', 'Available'),
(94, 43, 'B43-C1', 'Available'),
(95, 19, 'B19-C1', 'Available'),
(96, 88, 'B88-C1', 'Available'),
(97, 22, 'B22-C1', 'Available'),
(98, 175, 'B175-C1', 'Available'),
(99, 72, 'B72-C1', 'Available'),
(100, 29, 'B29-C1', 'Available'),
(101, 76, 'B76-C1', 'Available'),
(102, 18, 'B18-C1', 'Available'),
(103, 92, 'B92-C1', 'Available'),
(104, 81, 'B81-C1', 'Available'),
(105, 112, 'B112-C1', 'Available'),
(106, 120, 'B120-C1', 'Available'),
(107, 115, 'B115-C1', 'Available'),
(108, 38, 'B38-C1', 'Available'),
(109, 194, 'B194-C1', 'Available'),
(110, 200, 'B200-C1', 'Available'),
(111, 131, 'B131-C1', 'Available'),
(112, 116, 'B116-C1', 'Available'),
(113, 199, 'B199-C1', 'Available'),
(114, 86, 'B86-C1', 'Available'),
(115, 97, 'B97-C1', 'Available'),
(116, 16, 'B16-C1', 'Available'),
(117, 163, 'B163-C1', 'Available'),
(118, 74, 'B74-C1', 'Available'),
(119, 157, 'B157-C1', 'Available'),
(120, 109, 'B109-C1', 'Available'),
(121, 164, 'B164-C1', 'Available'),
(122, 156, 'B156-C1', 'Available'),
(123, 145, 'B145-C1', 'Available'),
(124, 65, 'B65-C1', 'Available'),
(125, 155, 'B155-C1', 'Available'),
(126, 61, 'B61-C1', 'Available'),
(127, 162, 'B162-C1', 'Available'),
(128, 94, 'B94-C1', 'Available'),
(129, 67, 'B67-C1', 'Available'),
(130, 140, 'B140-C1', 'Available'),
(131, 79, 'B79-C1', 'Available'),
(132, 111, 'B111-C1', 'Available'),
(133, 28, 'B28-C1', 'Available'),
(134, 178, 'B178-C1', 'Available'),
(135, 26, 'B26-C1', 'Available'),
(136, 176, 'B176-C1', 'Available'),
(137, 189, 'B189-C1', 'Available'),
(138, 134, 'B134-C1', 'Available'),
(139, 87, 'B87-C1', 'Available'),
(140, 118, 'B118-C1', 'Available'),
(141, 10, 'B10-C1', 'Available'),
(142, 172, 'B172-C1', 'Available'),
(143, 66, 'B66-C1', 'Available'),
(144, 68, 'B68-C1', 'Available'),
(145, 126, 'B126-C1', 'Available'),
(146, 119, 'B119-C1', 'Available'),
(147, 195, 'B195-C1', 'Available'),
(148, 34, 'B34-C1', 'Available'),
(149, 85, 'B85-C1', 'Available'),
(150, 54, 'B54-C1', 'Available'),
(151, 197, 'B197-C1', 'Available'),
(152, 9, 'B9-C1', 'Available'),
(153, 58, 'B58-C1', 'Available'),
(154, 82, 'B82-C1', 'Available'),
(155, 110, 'B110-C1', 'Available'),
(156, 150, 'B150-C1', 'Available'),
(157, 198, 'B198-C1', 'Available'),
(158, 167, 'B167-C1', 'Available'),
(159, 71, 'B71-C1', 'Available'),
(160, 133, 'B133-C1', 'Available'),
(161, 75, 'B75-C1', 'Available'),
(162, 80, 'B80-C1', 'Available'),
(163, 95, 'B95-C1', 'Available'),
(164, 166, 'B166-C1', 'Available'),
(165, 177, 'B177-C1', 'Available'),
(166, 186, 'B186-C1', 'Available'),
(167, 188, 'B188-C1', 'Available'),
(168, 40, 'B40-C1', 'Available'),
(169, 152, 'B152-C1', 'Available'),
(170, 180, 'B180-C1', 'Available'),
(171, 30, 'B30-C1', 'Available'),
(172, 184, 'B184-C1', 'Available'),
(173, 24, 'B24-C1', 'Available'),
(174, 32, 'B32-C1', 'Available'),
(175, 192, 'B192-C1', 'Available'),
(176, 191, 'B191-C1', 'Available'),
(177, 187, 'B187-C1', 'Available'),
(178, 37, 'B37-C1', 'Available'),
(179, 182, 'B182-C1', 'Available'),
(180, 183, 'B183-C1', 'Available'),
(181, 190, 'B190-C1', 'Available'),
(182, 127, 'B127-C1', 'Available'),
(183, 137, 'B137-C1', 'Available'),
(184, 138, 'B138-C1', 'Available'),
(185, 117, 'B117-C1', 'Available'),
(186, 15, 'B15-C1', 'Available'),
(187, 41, 'B41-C1', 'Available'),
(188, 23, 'B23-C1', 'Available'),
(189, 25, 'B25-C1', 'Available'),
(190, 27, 'B27-C1', 'Available'),
(191, 128, 'B128-C1', 'Available'),
(192, 193, 'B193-C1', 'Available'),
(193, 179, 'B179-C1', 'Available'),
(194, 31, 'B31-C1', 'Available'),
(195, 35, 'B35-C1', 'Available'),
(196, 185, 'B185-C1', 'Available'),
(197, 169, 'B169-C1', 'Available'),
(198, 33, 'B33-C1', 'Available'),
(199, 151, 'B151-C1', 'Available'),
(200, 64, 'B64-C1', 'Available'),
(256, 73, 'B73-C2', 'Available'),
(257, 89, 'B89-C2', 'Available'),
(258, 129, 'B129-C2', 'Available'),
(259, 136, 'B136-C2', 'Available'),
(260, 121, 'B121-C2', 'Available'),
(261, 113, 'B113-C2', 'Available'),
(262, 114, 'B114-C2', 'Available'),
(263, 124, 'B124-C2', 'Available'),
(264, 161, 'B161-C2', 'Available'),
(265, 69, 'B69-C2', 'Available'),
(266, 148, 'B148-C2', 'Available'),
(267, 60, 'B60-C2', 'Available'),
(268, 153, 'B153-C2', 'Available'),
(269, 130, 'B130-C2', 'Available'),
(270, 165, 'B165-C2', 'Available'),
(271, 154, 'B154-C2', 'Available'),
(272, 98, 'B98-C2', 'Available'),
(273, 59, 'B59-C2', 'Available'),
(274, 96, 'B96-C2', 'Available'),
(275, 147, 'B147-C2', 'Available'),
(276, 51, 'B51-C2', 'Available'),
(277, 77, 'B77-C2', 'Available'),
(278, 78, 'B78-C2', 'Available'),
(279, 101, 'B101-C2', 'Available'),
(280, 103, 'B103-C2', 'Available'),
(281, 100, 'B100-C2', 'Available'),
(282, 132, 'B132-C2', 'Available'),
(283, 8, 'B8-C2', 'Available'),
(284, 102, 'B102-C2', 'Available'),
(285, 55, 'B55-C2', 'Available'),
(286, 52, 'B52-C2', 'Available'),
(287, 146, 'B146-C2', 'Available'),
(288, 142, 'B142-C2', 'Available'),
(289, 20, 'B20-C2', 'Available'),
(290, 139, 'B139-C2', 'Available'),
(291, 143, 'B143-C2', 'Available'),
(292, 196, 'B196-C2', 'Available'),
(293, 173, 'B173-C2', 'Available'),
(294, 158, 'B158-C2', 'Available'),
(295, 99, 'B99-C2', 'Available'),
(296, 159, 'B159-C2', 'Available'),
(297, 45, 'B45-C2', 'Available'),
(298, 174, 'B174-C2', 'Available'),
(299, 105, 'B105-C2', 'Available'),
(300, 70, 'B70-C2', 'Available'),
(301, 144, 'B144-C2', 'Available'),
(302, 56, 'B56-C2', 'Available'),
(303, 106, 'B106-C2', 'Available'),
(304, 1, 'B1-C2', 'Available'),
(305, 57, 'B57-C2', 'Available'),
(306, 7, 'B7-C2', 'Available'),
(307, 108, 'B108-C2', 'Available'),
(308, 107, 'B107-C2', 'Available'),
(309, 91, 'B91-C2', 'Available'),
(310, 181, 'B181-C2', 'Available'),
(311, 44, 'B44-C2', 'Available'),
(312, 42, 'B42-C2', 'Available'),
(313, 63, 'B63-C2', 'Available'),
(314, 6, 'B6-C2', 'Available'),
(315, 149, 'B149-C2', 'Available'),
(316, 141, 'B141-C2', 'Available'),
(317, 62, 'B62-C2', 'Available'),
(318, 135, 'B135-C2', 'Available'),
(319, 53, 'B53-C2', 'Available'),
(320, 104, 'B104-C2', 'Available'),
(321, 160, 'B160-C2', 'Available'),
(322, 168, 'B168-C2', 'Available'),
(323, 93, 'B93-C2', 'Available'),
(324, 83, 'B83-C2', 'Available'),
(325, 90, 'B90-C2', 'Available'),
(326, 11, 'B11-C2', 'Available'),
(327, 170, 'B170-C2', 'Available'),
(328, 2, 'B2-C2', 'Available'),
(329, 4, 'B4-C2', 'Available'),
(330, 84, 'B84-C2', 'Available'),
(331, 14, 'B14-C2', 'Available'),
(332, 48, 'B48-C2', 'Available'),
(333, 49, 'B49-C2', 'Available'),
(334, 50, 'B50-C2', 'Available'),
(335, 171, 'B171-C2', 'Available'),
(336, 3, 'B3-C2', 'Available'),
(337, 36, 'B36-C2', 'Available'),
(338, 39, 'B39-C2', 'Available'),
(339, 5, 'B5-C2', 'Available'),
(340, 125, 'B125-C2', 'Available'),
(341, 122, 'B122-C2', 'Available'),
(342, 123, 'B123-C2', 'Available'),
(343, 12, 'B12-C2', 'Available'),
(344, 13, 'B13-C2', 'Available'),
(345, 46, 'B46-C2', 'Available'),
(346, 47, 'B47-C2', 'Available'),
(347, 21, 'B21-C2', 'Available'),
(348, 17, 'B17-C2', 'Available'),
(349, 43, 'B43-C2', 'Available'),
(350, 19, 'B19-C2', 'Available'),
(351, 88, 'B88-C2', 'Available'),
(352, 22, 'B22-C2', 'Available'),
(353, 175, 'B175-C2', 'Available'),
(354, 72, 'B72-C2', 'Available'),
(355, 29, 'B29-C2', 'Available'),
(356, 76, 'B76-C2', 'Available'),
(357, 18, 'B18-C2', 'Available'),
(358, 92, 'B92-C2', 'Available'),
(359, 81, 'B81-C2', 'Available'),
(360, 112, 'B112-C2', 'Available'),
(361, 120, 'B120-C2', 'Available'),
(362, 115, 'B115-C2', 'Available'),
(363, 38, 'B38-C2', 'Available'),
(364, 194, 'B194-C2', 'Available'),
(365, 200, 'B200-C2', 'Available'),
(366, 131, 'B131-C2', 'Available'),
(367, 116, 'B116-C2', 'Available'),
(368, 199, 'B199-C2', 'Available'),
(369, 86, 'B86-C2', 'Available'),
(370, 97, 'B97-C2', 'Available'),
(371, 16, 'B16-C2', 'Available'),
(372, 163, 'B163-C2', 'Available'),
(373, 74, 'B74-C2', 'Available'),
(374, 157, 'B157-C2', 'Available'),
(375, 109, 'B109-C2', 'Available'),
(376, 164, 'B164-C2', 'Available'),
(377, 156, 'B156-C2', 'Available'),
(378, 145, 'B145-C2', 'Available'),
(379, 65, 'B65-C2', 'Available'),
(380, 155, 'B155-C2', 'Available'),
(381, 61, 'B61-C2', 'Available'),
(382, 162, 'B162-C2', 'Available'),
(383, 94, 'B94-C2', 'Available'),
(384, 67, 'B67-C2', 'Available'),
(385, 140, 'B140-C2', 'Available'),
(386, 79, 'B79-C2', 'Available'),
(387, 111, 'B111-C2', 'Available'),
(388, 28, 'B28-C2', 'Available'),
(389, 178, 'B178-C2', 'Available'),
(390, 26, 'B26-C2', 'Available'),
(391, 176, 'B176-C2', 'Available'),
(392, 189, 'B189-C2', 'Available'),
(393, 134, 'B134-C2', 'Available'),
(394, 87, 'B87-C2', 'Available'),
(395, 118, 'B118-C2', 'Available'),
(396, 10, 'B10-C2', 'Available'),
(397, 172, 'B172-C2', 'Available'),
(398, 66, 'B66-C2', 'Available'),
(399, 68, 'B68-C2', 'Available'),
(400, 126, 'B126-C2', 'Available'),
(401, 119, 'B119-C2', 'Available'),
(402, 195, 'B195-C2', 'Available'),
(403, 34, 'B34-C2', 'Available'),
(404, 85, 'B85-C2', 'Available'),
(405, 54, 'B54-C2', 'Available'),
(406, 197, 'B197-C2', 'Available'),
(407, 9, 'B9-C2', 'Available'),
(408, 58, 'B58-C2', 'Available'),
(409, 82, 'B82-C2', 'Available'),
(410, 110, 'B110-C2', 'Available'),
(411, 150, 'B150-C2', 'Available'),
(412, 198, 'B198-C2', 'Available'),
(413, 167, 'B167-C2', 'Available'),
(414, 71, 'B71-C2', 'Available'),
(415, 133, 'B133-C2', 'Available'),
(416, 75, 'B75-C2', 'Available'),
(417, 80, 'B80-C2', 'Available'),
(418, 95, 'B95-C2', 'Available'),
(419, 166, 'B166-C2', 'Available'),
(420, 177, 'B177-C2', 'Available'),
(421, 186, 'B186-C2', 'Available'),
(422, 188, 'B188-C2', 'Available'),
(423, 40, 'B40-C2', 'Available'),
(424, 152, 'B152-C2', 'Available'),
(425, 180, 'B180-C2', 'Available'),
(426, 30, 'B30-C2', 'Available'),
(427, 184, 'B184-C2', 'Available'),
(428, 24, 'B24-C2', 'Available'),
(429, 32, 'B32-C2', 'Available'),
(430, 192, 'B192-C2', 'Available'),
(431, 191, 'B191-C2', 'Available'),
(432, 187, 'B187-C2', 'Available'),
(433, 37, 'B37-C2', 'Available'),
(434, 182, 'B182-C2', 'Available'),
(435, 183, 'B183-C2', 'Available'),
(436, 190, 'B190-C2', 'Available'),
(437, 127, 'B127-C2', 'Available'),
(438, 137, 'B137-C2', 'Available'),
(439, 138, 'B138-C2', 'Available'),
(440, 117, 'B117-C2', 'Available'),
(441, 15, 'B15-C2', 'Available'),
(442, 41, 'B41-C2', 'Available'),
(443, 23, 'B23-C2', 'Available'),
(444, 25, 'B25-C2', 'Available'),
(445, 27, 'B27-C2', 'Available'),
(446, 128, 'B128-C2', 'Available'),
(447, 193, 'B193-C2', 'Available'),
(448, 179, 'B179-C2', 'Available'),
(449, 31, 'B31-C2', 'Available'),
(450, 35, 'B35-C2', 'Available'),
(451, 185, 'B185-C2', 'Available'),
(452, 169, 'B169-C2', 'Available'),
(453, 33, 'B33-C2', 'Available'),
(454, 151, 'B151-C2', 'Available'),
(455, 64, 'B64-C2', 'Available');

-- --------------------------------------------------------

--
-- Table structure for table `transactions`
--

CREATE TABLE `transactions` (
  `transaction_id` int(11) NOT NULL,
  `copy_id` int(11) NOT NULL,
  `member_id` int(11) NOT NULL,
  `issue_date` datetime NOT NULL DEFAULT current_timestamp(),
  `due_date` datetime NOT NULL,
  `return_date` datetime DEFAULT NULL,
  `status` enum('Active','Returned') NOT NULL DEFAULT 'Active',
  `fine_amount` decimal(10,2) NOT NULL DEFAULT 0.00,
  `active_copy_id` int(11) GENERATED ALWAYS AS (case when `return_date` is null then `copy_id` else NULL end) STORED
) ;

--
-- Dumping data for table `transactions`
--

INSERT INTO `transactions` (`transaction_id`, `copy_id`, `member_id`, `issue_date`, `due_date`, `return_date`, `status`, `fine_amount`) VALUES
(1, 49, 1, '2026-11-03 12:35:11', '2026-11-17 12:35:11', NULL, 'Active', 0.00),
(2, 73, 2, '2026-10-19 12:36:15', '2026-11-02 12:36:15', NULL, 'Active', 0.00),
(3, 84, 3, '2026-11-06 12:36:30', '2026-11-20 12:36:30', NULL, 'Active', 0.00);

--
-- Triggers `transactions`
--
DELIMITER $$
CREATE TRIGGER `trg_transactions_after_update` AFTER UPDATE ON `transactions` FOR EACH ROW BEGIN
    IF OLD.return_date IS NULL AND NEW.return_date IS NOT NULL THEN
        UPDATE physical_copies
        SET status = 'Available'
        WHERE copy_id = NEW.copy_id
          AND status = 'Issued';
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `trg_transactions_before_insert` BEFORE INSERT ON `transactions` FOR EACH ROW BEGIN
    IF NEW.return_date IS NOT NULL OR NEW.status <> 'Active' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A new loan must start as Active and not returned.';
    END IF;

    UPDATE physical_copies
    SET status = 'Issued'
    WHERE copy_id = NEW.copy_id
      AND status = 'Available';

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'This physical copy does not exist or is not available.';
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Stand-in structure for view `v_copy_availability`
-- (See below for the actual view)
--
CREATE TABLE `v_copy_availability` (
`book_id` int(11)
,`title` varchar(255)
,`author` varchar(255)
,`category` varchar(100)
,`copy_id` int(11)
,`copy_identifier` varchar(50)
,`copy_status` enum('Available','Issued','Damaged','Lost')
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `v_fine_payment_summary`
-- (See below for the actual view)
--
CREATE TABLE `v_fine_payment_summary` (
`transaction_id` int(11)
,`member_id` int(11)
,`member_name` varchar(100)
,`book_title` varchar(255)
,`total_fine` decimal(10,2)
,`total_paid` decimal(32,2)
,`outstanding_balance` decimal(33,2)
,`payment_status` varchar(14)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `v_library_summary`
-- (See below for the actual view)
--
CREATE TABLE `v_library_summary` (
`total_book_titles` bigint(21)
,`total_copies` bigint(21)
,`available_copies` bigint(21)
,`issued_copies` bigint(21)
,`overdue_copies` bigint(21)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `v_overdue_items`
-- (See below for the actual view)
--
CREATE TABLE `v_overdue_items` (
`transaction_id` int(11)
,`title` varchar(255)
,`copy_identifier` varchar(50)
,`member_id` int(11)
,`member_name` varchar(100)
,`phone` varchar(20)
,`issue_date` datetime
,`due_date` datetime
,`overdue_days` int(7)
,`current_fine_estimate` decimal(16,2)
);

-- --------------------------------------------------------

--
-- Structure for view `v_copy_availability`
--
DROP TABLE IF EXISTS `v_copy_availability`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v_copy_availability`  AS SELECT `b`.`book_id` AS `book_id`, `b`.`title` AS `title`, `b`.`author` AS `author`, `b`.`category` AS `category`, `p`.`copy_id` AS `copy_id`, `p`.`copy_identifier` AS `copy_identifier`, `p`.`status` AS `copy_status` FROM (`books` `b` join `physical_copies` `p` on(`p`.`book_id` = `b`.`book_id`)) ;

-- --------------------------------------------------------

--
-- Structure for view `v_fine_payment_summary`
--
DROP TABLE IF EXISTS `v_fine_payment_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v_fine_payment_summary`  AS SELECT `t`.`transaction_id` AS `transaction_id`, `t`.`member_id` AS `member_id`, `m`.`name` AS `member_name`, `b`.`title` AS `book_title`, `t`.`fine_amount` AS `total_fine`, coalesce(sum(`fp`.`amount`),0.00) AS `total_paid`, greatest(`t`.`fine_amount` - coalesce(sum(`fp`.`amount`),0.00),0.00) AS `outstanding_balance`, CASE WHEN `t`.`fine_amount` <= 0 THEN 'No Fine' WHEN coalesce(sum(`fp`.`amount`),0.00) = 0 THEN 'Unpaid' WHEN coalesce(sum(`fp`.`amount`),0.00) < `t`.`fine_amount` THEN 'Partially Paid' ELSE 'Paid' END AS `payment_status` FROM ((((`transactions` `t` join `members` `m` on(`m`.`member_id` = `t`.`member_id`)) join `physical_copies` `pc` on(`pc`.`copy_id` = `t`.`copy_id`)) join `books` `b` on(`b`.`book_id` = `pc`.`book_id`)) left join `fine_payments` `fp` on(`fp`.`transaction_id` = `t`.`transaction_id`)) WHERE `t`.`status` = 'Returned' GROUP BY `t`.`transaction_id`, `t`.`member_id`, `m`.`name`, `b`.`title`, `t`.`fine_amount` ;

-- --------------------------------------------------------

--
-- Structure for view `v_library_summary`
--
DROP TABLE IF EXISTS `v_library_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v_library_summary`  AS SELECT (select count(0) from `books`) AS `total_book_titles`, (select count(0) from `physical_copies`) AS `total_copies`, (select count(0) from `physical_copies` where `physical_copies`.`status` = 'Available') AS `available_copies`, (select count(0) from `physical_copies` where `physical_copies`.`status` = 'Issued') AS `issued_copies`, (select count(0) from `transactions` where `transactions`.`status` = 'Active' and `transactions`.`return_date` is null and `transactions`.`due_date` < current_timestamp()) AS `overdue_copies` ;

-- --------------------------------------------------------

--
-- Structure for view `v_overdue_items`
--
DROP TABLE IF EXISTS `v_overdue_items`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v_overdue_items`  AS SELECT `t`.`transaction_id` AS `transaction_id`, `b`.`title` AS `title`, `p`.`copy_identifier` AS `copy_identifier`, `m`.`member_id` AS `member_id`, `m`.`name` AS `member_name`, `m`.`phone` AS `phone`, `t`.`issue_date` AS `issue_date`, `t`.`due_date` AS `due_date`, to_days(curdate()) - to_days(cast(`t`.`due_date` as date)) AS `overdue_days`, greatest(to_days(curdate()) - to_days(cast(`t`.`due_date` as date)),0) * `s`.`fine_per_day` AS `current_fine_estimate` FROM ((((`transactions` `t` join `physical_copies` `p` on(`p`.`copy_id` = `t`.`copy_id`)) join `books` `b` on(`b`.`book_id` = `p`.`book_id`)) join `members` `m` on(`m`.`member_id` = `t`.`member_id`)) join `library_settings` `s`) WHERE `t`.`status` = 'Active' AND `t`.`return_date` is null AND `t`.`due_date` < current_timestamp() AND `s`.`setting_id` = 1 ;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `books`
--
ALTER TABLE `books`
  ADD PRIMARY KEY (`book_id`),
  ADD UNIQUE KEY `isbn` (`isbn`),
  ADD KEY `idx_books_title` (`title`),
  ADD KEY `idx_books_author` (`author`),
  ADD KEY `idx_books_category` (`category`);

--
-- Indexes for table `fine_payments`
--
ALTER TABLE `fine_payments`
  ADD PRIMARY KEY (`payment_id`),
  ADD UNIQUE KEY `uq_payment_reference` (`payment_reference`),
  ADD KEY `idx_fine_payments_transaction` (`transaction_id`),
  ADD KEY `idx_fine_payments_date` (`payment_date`);

--
-- Indexes for table `library_settings`
--
ALTER TABLE `library_settings`
  ADD PRIMARY KEY (`setting_id`);

--
-- Indexes for table `members`
--
ALTER TABLE `members`
  ADD PRIMARY KEY (`member_id`),
  ADD UNIQUE KEY `email` (`email`),
  ADD KEY `idx_members_name` (`name`);

--
-- Indexes for table `physical_copies`
--
ALTER TABLE `physical_copies`
  ADD PRIMARY KEY (`copy_id`),
  ADD UNIQUE KEY `copy_identifier` (`copy_identifier`),
  ADD KEY `idx_copies_book` (`book_id`),
  ADD KEY `idx_copies_status` (`status`);

--
-- Indexes for table `transactions`
--
ALTER TABLE `transactions`
  ADD PRIMARY KEY (`transaction_id`),
  ADD UNIQUE KEY `uq_one_active_loan_per_copy` (`active_copy_id`),
  ADD KEY `idx_transactions_member` (`member_id`),
  ADD KEY `idx_transactions_copy` (`copy_id`),
  ADD KEY `idx_transactions_due_status` (`due_date`,`status`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `books`
--
ALTER TABLE `books`
  MODIFY `book_id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=201;

--
-- AUTO_INCREMENT for table `fine_payments`
--
ALTER TABLE `fine_payments`
  MODIFY `payment_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `members`
--
ALTER TABLE `members`
  MODIFY `member_id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=11;

--
-- AUTO_INCREMENT for table `physical_copies`
--
ALTER TABLE `physical_copies`
  MODIFY `copy_id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=456;

--
-- AUTO_INCREMENT for table `transactions`
--
ALTER TABLE `transactions`
  MODIFY `transaction_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- Constraints for dumped tables
--

--
-- Constraints for table `fine_payments`
--
ALTER TABLE `fine_payments`
  ADD CONSTRAINT `fk_payment_transaction` FOREIGN KEY (`transaction_id`) REFERENCES `transactions` (`transaction_id`) ON UPDATE CASCADE;

--
-- Constraints for table `physical_copies`
--
ALTER TABLE `physical_copies`
  ADD CONSTRAINT `physical_copies_ibfk_1` FOREIGN KEY (`book_id`) REFERENCES `books` (`book_id`) ON UPDATE CASCADE;

--
-- Constraints for table `transactions`
--
ALTER TABLE `transactions`
  ADD CONSTRAINT `transactions_ibfk_1` FOREIGN KEY (`copy_id`) REFERENCES `physical_copies` (`copy_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `transactions_ibfk_2` FOREIGN KEY (`member_id`) REFERENCES `members` (`member_id`) ON UPDATE CASCADE;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
