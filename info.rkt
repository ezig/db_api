#lang info

(define shill-plugin-name 'db)
(define shill-plugin-require 'db_api/db_api)
(define shill-plugin-ambient '(make-dbview))
(define shill-plugin-interfaces '(dbview))